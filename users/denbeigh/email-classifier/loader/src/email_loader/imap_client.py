"""IMAP client for fetching emails from Exchange Online via Outlook.

Handles connection, folder listing (with UTF-7 decode), and incremental
UID-based fetch using BODY.PEEK[] to avoid marking messages as read.
"""

import base64
import contextlib
import datetime
import imaplib
import re
import time
from collections.abc import Callable
from email.message import Message
from pathlib import Path

from email_loader.config import Config, OAuth2Config

# ── modified UTF-7 decoder (RFC 3501 §5.1.3) ────────────────

_UTF7_RE = re.compile(r"&([A-Za-z0-9+/]+(?:,[A-Za-z0-9+/]+)*)?-")


def _decode_utf7(name: str) -> str:
    """Decode an IMAP modified-UTF-7 mailbox name to Unicode."""

    def _replace(m: re.Match) -> str:
        raw = m.group(1)
        if raw is None:
            # "&-" is the escape for literal "&"
            return "&"
        # IMAP uses comma instead of slash for base64
        # Also, padding is implicit — no trailing =
        raw = raw.replace(",", "/")
        # Ensure correct padding
        padding = 4 - (len(raw) % 4)
        if padding != 4:
            raw += "=" * padding
        decoded_bytes = base64.b64decode(raw, validate=False)
        return decoded_bytes.decode("utf-16-be", errors="replace")

    return _UTF7_RE.sub(_replace, name)


# ── helpers ──────────────────────────────────────────────────


def _slugify(name: str) -> str:
    """Turn an IMAP folder name into a filesystem-safe slug."""
    s = name.lower().replace(" ", "-")
    s = re.sub(r"[^a-z0-9-]", "", s)
    return s.strip("-") or "root"


def _preview_from_message(msg: Message, max_chars: int = 1000) -> str:
    """Extract a plain-text preview from an email Message."""
    # Walk through all parts looking for text content
    texts: list[str] = []
    for part in msg.walk():
        content_type = part.get_content_type()
        if content_type == "text/plain":
            payload = part.get_payload(decode=True)
            if isinstance(payload, bytes):
                charset = part.get_content_charset() or "utf-8"
                try:
                    texts.append(payload.decode(charset, errors="replace"))
                except LookupError:
                    texts.append(payload.decode("utf-8", errors="replace"))
                break  # prefer first plain part
        elif content_type == "text/html":
            payload = part.get_payload(decode=True)
            if isinstance(payload, bytes):
                texts.append(payload.decode("utf-8", errors="replace"))
                break  # only use first html if no plain found

    if not texts:
        # Fallback: get the first text/* payload we can find
        for part in msg.walk():
            if part.get_content_maintype() == "text":
                payload = part.get_payload(decode=True)
                if isinstance(payload, bytes):
                    texts.append(payload.decode("utf-8", errors="replace"))
                    break

    text = "\n".join(texts)
    # Strip quoted/replied lines (heuristic)
    lines = [line for line in text.splitlines() if not line.startswith(">")]
    text = "\n".join(lines)
    # Collapse whitespace
    text = re.sub(r"\s+", " ", text).strip()
    return text[:max_chars]


def _to_imap_date(iso_str: str) -> str:
    """Convert an ISO-8601 date string to IMAP date format (DD-Mon-YYYY).

    Handles both bare dates ("2020-01-01") and datetime strings
    ("2020-01-01T00:00:00+00:00").  Bare dates are treated as UTC.
    """
    dt = datetime.datetime.fromisoformat(iso_str)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.UTC)
    return dt.strftime("%d-%b-%Y")


# ── progress callback type ───────────────────────────────────

ProgressFn = Callable[[str, int, int], None]
"""Args: folder_name, current_uid, total_to_fetch (0 = unknown)."""


# ── IMAP client ──────────────────────────────────────────────


class IMAPClient:
    """Low-level IMAP operations for email fetching."""

    def __init__(self, config: Config) -> None:
        self.config = config
        self._conn: imaplib.IMAP4_SSL | None = None

    # ── connection ──────────────────────────────────────────

    def connect(self) -> None:
        cfg = self.config.imap
        self._conn = imaplib.IMAP4_SSL(cfg.host, cfg.port, timeout=30)

        if cfg.oauth2.client_id:
            self._oauth2_authenticate(cfg.username, cfg.oauth2)
        else:
            self._conn.login(cfg.username, cfg.password)

    # ── OAuth2 helpers ─────────────────────────────────────

    def _oauth2_authenticate(
        self,
        username: str,
        oauth2: OAuth2Config,
    ) -> None:
        """Authenticate via SASL XOAUTH2 using MSAL client-credentials flow.

        Retries once after purging the token cache on failure — this handles
        the case where app permissions have changed and the cached token
        carries stale roles.
        """
        assert self._conn is not None

        token = self._acquire_token(oauth2)
        sasl = f"user={username}\x01auth=Bearer {token}\x01\x01".encode("ascii")

        try:
            self._conn.authenticate("XOAUTH2", lambda _c: sasl)
        except imaplib.IMAP4.error:
            # Auth failed — likely stale cached token. Purge cache and retry.
            cache_path = self.config.storage.expanded_dir / "msal_token_cache.bin"
            cache_path.unlink(missing_ok=True)

            token = self._acquire_token(oauth2)
            sasl = f"user={username}\x01auth=Bearer {token}\x01\x01".encode("ascii")
            self._conn.authenticate("XOAUTH2", lambda _c: sasl)

    def _acquire_token(self, oauth2: OAuth2Config) -> str:
        """Get an OAuth2 access token via MSAL client-credentials flow.

        Uses the MSAL token cache so subsequent runs reuse cached tokens
        (MSAL handles automatic refresh on expiry).
        """
        from msal import ConfidentialClientApplication, SerializableTokenCache

        cache_path = self.config.storage.expanded_dir / "msal_token_cache.bin"

        cache = SerializableTokenCache()
        if cache_path.exists():
            cache.deserialize(cache_path.read_text())

        app = ConfidentialClientApplication(
            oauth2.client_id,
            client_credential=oauth2.client_secret,
            authority=oauth2.authority,
            token_cache=cache,
        )

        # App-only flow — no user involved, no MFA problem
        result: dict[str, str] = app.acquire_token_for_client(scopes=oauth2.imap_scopes)  # type: ignore[assignment]

        if "access_token" not in result:
            error = result.get(
                "error_description",
                result.get("error", str(result)),
            )
            raise RuntimeError(f"OAuth2 token acquisition failed: {error}")

        # Persist cache so subsequent runs don't need to re-authenticate
        if cache.has_state_changed:
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_text(cache.serialize())

        return result["access_token"]

    def disconnect(self) -> None:
        if self._conn:
            with contextlib.suppress(Exception):
                self._conn.logout()
            self._conn = None

    def reconnect(self) -> None:
        """Close the existing connection and open a new one.

        Re-authenticates with a fresh OAuth2 token.  Safe to call when
        the connection has been dropped or the access token has expired.
        Retries up to 3 times with exponential backoff on transient
        connection failures.
        """
        self.disconnect()
        last_exc: Exception | None = None
        for attempt in range(3):
            try:
                self.connect()
                return
            except (imaplib.IMAP4.abort, OSError) as exc:
                last_exc = exc
                if attempt < 2:
                    time.sleep(1.0 * (2**attempt))
                    self.disconnect()
                    continue
                raise
        raise RuntimeError("Reconnect failed after 3 attempts") from last_exc

    def _ensure_connected(self) -> None:
        """Verify the IMAP connection is alive; reconnect if not.

        Uses ``NOOP`` — a lightweight round-trip that doesn't affect
        server state.  Safe to call between folder syncs.
        """
        if self._conn is None:
            self.connect()
            return
        try:
            self._conn.noop()
        except imaplib.IMAP4.abort, OSError:
            self.reconnect()

    # ── folder listing ──────────────────────────────────────

    def list_folders(self) -> list[tuple[str, str, str]]:
        """Return list of (flags, delimiter, utf8_name) for all folders.

        Filters out \\Noselect folders (container-only entries that can't
        hold messages) and any listed in skip_folders.
        """
        assert self._conn is not None
        raw_list = self._conn.list()
        # raw_list[1] is a list of byte strings like:
        # b'(\\HasNoChildren) "/" "INBOX"'
        # b'(\\HasChildren \\Noselect) "/" "[Gmail]"'
        # imaplib.list() returns mixed-type results; filter to bytes for safety.
        raw_items: list[bytes] = [item for item in raw_list[1] if isinstance(item, bytes)]
        folders: list[tuple[str, str, str]] = []
        for item in raw_items:
            decoded = item.decode("utf-8", errors="replace")
            # Parse the raw LIST response to extract delimiter and name
            # Format: (\\Flags) "/" "Name"   or (\\Flags) "/" Name   or (\\Flags) "/" {length}\r\nname
            m = re.match(
                r'\((?P<flags>[^)]*)\)\s+"(?P<delim>[^"]*)"\s+'  # flags + delimiter
                r'(?:"(?P<qname>[^"]*)"|\{(?P<litlen>\d+)\}|(?P<uname>[^\s")]+))',
                decoded,
            )
            if not m:
                continue
            flags_str = m.group("flags")
            delim = m.group("delim")

            if m.group("litlen") is not None:
                # LITERAL+ response: name is on the next line(s) — skip for now
                continue

            name_utf7 = m.group("qname") if m.group("qname") is not None else m.group("uname")
            if name_utf7 is None:
                continue
            name = _decode_utf7(name_utf7)

            if "\\Noselect" in flags_str:
                continue

            skip = self.config.skip_folders
            if name in skip:
                continue

            folders.append((flags_str, delim, name))
        return folders

    # ── folder sync ─────────────────────────────────────────

    def _select_folder(self, folder_name: str) -> None:
        """SELECT *folder_name* and raise on failure.

        Extracted so both ``sync_folder`` and the retry path can
        re-select after a reconnect.
        """
        assert self._conn is not None
        quoted = self._conn._quote(folder_name)
        status, resp = self._conn.select(quoted, readonly=True)
        if status != "OK":
            err_raw = resp[0] if resp else b"unknown"
            err = (
                err_raw.decode("utf-8", errors="replace")
                if isinstance(err_raw, bytes)
                else str(err_raw)
            )
            raise RuntimeError(f"SELECT {folder_name!r} failed: {err}")

    def sync_folder(
        self,
        folder_name: str,
        *,
        uid_validity: int,
        last_synced_uid: int,
        eml_dir: Path,
        on_message: Callable[[bytes, int, str, str], None],
        on_progress: ProgressFn | None = None,
        limit: int | None = None,
        skip_before: str | None = None,
        batch_size: int = 100,
    ) -> tuple[int, int]:
        """Fetch new/changed messages from one folder.

        Returns (new_uid_validity, last_fetched_uid).

        *last_fetched_uid* is the highest UID that was actually processed
        (accounting for *limit*).  The caller should persist this so the
        next sync can use ``last_fetched_uid + 1:*`` as the search range.

        When *last_synced_uid* is 0 or UIDVALIDITY has changed, does a
        full scan — optionally filtered by *skip_before* via an IMAP
        ``SINCE`` search to avoid fetching messages before the cutoff.

        On authentication failure (stale OAuth2 token) the connection is
        re-established with a fresh token and the current batch is retried.

        Calls *on_message* for each new message with:
          (raw_bytes, uid, folder_slug, eml_filename)
        The caller is responsible for writing the .eml file and DB insert.
        """
        assert self._conn is not None
        folder_slug = _slugify(folder_name)

        # ── Connection-retry loop ──
        connection_retries = 3

        for sync_attempt in range(connection_retries):
            try:
                # ── SELECT folder ──
                self._select_folder(folder_name)

                # Parse UIDVALIDITY from the untagged responses.
                uidval_raw = self._conn.untagged_responses.get("UIDVALIDITY", [None])[0]
                if uidval_raw is None:
                    raise RuntimeError(f"Could not determine UIDVALIDITY for {folder_name!r}")
                if isinstance(uidval_raw, bytes):
                    uidval_text = uidval_raw.decode("ascii")
                else:
                    uidval_text = str(uidval_raw[0])
                new_uid_validity = int(uidval_text)

                # ── Determine UIDs to fetch ──
                uid_validity_changed = new_uid_validity != uid_validity

                if uid_validity_changed or last_synced_uid == 0:
                    # Full scan — optionally filtered by date
                    if skip_before:
                        imap_date = _to_imap_date(skip_before)
                        search_cmd = f"SINCE {imap_date}"
                    else:
                        search_cmd = "ALL"
                else:
                    search_cmd = f"{last_synced_uid + 1}:*"

                status, data = self._conn.uid("SEARCH", search_cmd)
                if status != "OK":
                    raise RuntimeError(f"UID SEARCH {search_cmd!r} failed in {folder_name!r}")

                uid_list: list[int] = []
                if data[0]:
                    uid_list = [int(uid) for uid in data[0].split()]

                if not uid_list:
                    return (new_uid_validity, 0)

                total = len(uid_list)
                if limit is not None:
                    uid_list = uid_list[:limit]
                    total = len(uid_list)

                # ── Fetch in batches, with reconnect-on-failure retry ──
                for i in range(0, len(uid_list), batch_size):
                    batch = uid_list[i : i + batch_size]
                    batch_str = ",".join(str(uid) for uid in batch)

                    try:
                        self._fetch_batch(batch, batch_str, folder_slug, eml_dir, on_message)
                    except IMAPAuthError, imaplib.IMAP4.abort, OSError:
                        # Transient error — reconnect, re-select, retry batch
                        for retry_attempt in range(3):
                            try:
                                self.reconnect()
                                self._select_folder(folder_name)
                                self._fetch_batch(
                                    batch, batch_str, folder_slug, eml_dir, on_message
                                )
                                break
                            except IMAPAuthError, imaplib.IMAP4.abort, OSError:
                                if retry_attempt < 2:
                                    time.sleep(1.0 * (2**retry_attempt))
                                    continue
                                raise

                    if on_progress:
                        # Progress as UIDs handed to the callback, regardless of
                        # whether each ends up fetched, skipped, or cache-recovered.
                        on_progress(folder_name, min(i + len(batch), total), total)

                last_uid = uid_list[-1]
                return (new_uid_validity, last_uid)

            except imaplib.IMAP4.abort, OSError:
                if sync_attempt < connection_retries - 1:
                    time.sleep(1.0 * (2**sync_attempt))
                    self.reconnect()
                    continue
                break

        raise RuntimeError(
            f"sync_folder failed for {folder_name!r} after {connection_retries} connection retries"
        )

    def _fetch_batch(
        self,
        batch: list[int],
        batch_str: str,
        folder_slug: str,
        eml_dir: Path,
        on_message: Callable[[bytes, int, str, str], None],
    ) -> None:
        """Fetch a batch of UIDs and call *on_message* for each.

        Raises ``IMAPAuthError`` if the server returns an authentication-related
        error, signalling the caller to reconnect and retry the batch.
        """
        assert self._conn is not None
        status, fetch_data = self._conn.uid("FETCH", batch_str, "(BODY.PEEK[] INTERNALDATE FLAGS)")
        if status != "OK":
            err_msg = fetch_data[0].decode("utf-8", errors="replace") if fetch_data else ""
            _check_auth_error(err_msg)
            # Non-auth failure — fall back to single-UID fetches
            time.sleep(0.5)
            for uid in batch:
                with contextlib.suppress(Exception):
                    f = self._conn.uid("FETCH", str(uid), "(BODY.PEEK[] INTERNALDATE FLAGS)")
                    if f[0] == "OK":
                        _process_fetch_response(f[1], uid, folder_slug, eml_dir, on_message)
            return

        # status == "OK" — process every UID in the batch
        for uid in batch:
            with contextlib.suppress(Exception):
                _process_fetch_response(fetch_data, uid, folder_slug, eml_dir, on_message)


class IMAPAuthError(Exception):
    """Raised when an IMAP command fails with an authentication-related error.

    Signals that the access token has likely expired and the caller should
    reconnect with a fresh token before retrying.
    """


def _check_auth_error(err_msg: str) -> None:
    """Raise ``IMAPAuthError`` if *err_msg* looks like an auth failure."""
    if not err_msg:
        return
    auth_indicators = [
        "AUTHENTICATIONFAILED",
        "AUTHFAILED",
        "NO",
        "authentication failed",
        "not authenticated",
        "login expired",
        "token expired",
    ]
    lower = err_msg.lower()
    for indicator in auth_indicators:
        if indicator.lower() in lower:
            raise IMAPAuthError(err_msg)


def _process_fetch_response(
    fetch_data: list,
    target_uid: int,
    folder_slug: str,
    _eml_dir: Path,  # noqa: ARG001
    on_message: Callable[[bytes, int, str, str], None],
) -> bool:
    """Process a single FETCH response for one UID.

    Iterates the full untagged-response list.  Entries are either:
      * ``(resp_line, body)`` tuples (a literal body), or
      * plain ``bytes`` (trailers / response fragments like ``b" UID 1)"``).

    Outlook / Exchange Online typically sends the UID fixnum *before*
    the ``BODY[]`` literal, so it lives in ``resp_line``.  For servers
    that place UID in the trailer we also scan the next entry (if it's
    plain bytes).

    Returns True if a matching UID was found and *on_message* called,
    False otherwise.
    """
    # Walk the list by index so we can peek at the next entry for trailers.
    for idx in range(len(fetch_data)):
        resp_part = fetch_data[idx]
        if not isinstance(resp_part, tuple):
            continue

        raw_resp, raw_body = resp_part
        if raw_body is None or raw_body == b"":
            continue

        # UID may be in this response line or in the next bytes trailer
        uid = _extract_uid(raw_resp)
        if uid is None and idx + 1 < len(fetch_data):
            trailer = fetch_data[idx + 1]
            if isinstance(trailer, bytes):
                uid = _extract_uid(trailer)

        if uid is None or uid != target_uid:
            continue

        eml_filename = f"{uid}.eml"
        on_message(raw_body, uid, folder_slug, eml_filename)
        return True
    return False


def _extract_uid(data: bytes) -> int | None:
    """Return the numeric UID from a FETCH response fragment, or None."""
    m = re.search(rb"UID\s+(\d+)", data)
    return int(m.group(1)) if m else None
