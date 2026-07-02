"""IMAP client for fetching emails from Exchange Online via Outlook.

Handles connection, folder listing (with UTF-7 decode), and incremental
UID-based fetch using BODY.PEEK[] to avoid marking messages as read.
"""

import base64
import contextlib
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

    # ── folder listing ──────────────────────────────────────

    def list_folders(self) -> list[tuple[str, str, str]]:
        """Return list of (flags, delimiter, utf8_name) for all folders.

        Filters out things like \\Noselect and skip_folders.
        """
        assert self._conn is not None
        raw_list = self._conn.list()
        # raw_list[1] is a list of byte strings like:
        # b'(\\HasNoChildren) "/" "INBOX"'
        # b'(\\HasChildren \\Noselect) "/" "[Gmail]"'
        raw_items: list[bytes] = raw_list[1]  # type: ignore[assignment]
        folders: list[tuple[str, str, str]] = []
        for item in raw_items:
            decoded = item.decode("utf-8", errors="replace")
            # Parse the raw LIST response to extract delimiter and name
            # Format: (\\Flags) "/" "Name"   or (\\Flags) "/" {length}\r\nname
            m = re.match(
                r'\((?P<flags>[^)]*)\)\s+"(?P<delim>[^"]*)"\s+"(?P<name>[^"]*)"',
                decoded,
            )
            if not m:
                # LITERAL+ response variant: (\\Flags) "/" {5}\r\nINBOX
                m2 = re.match(
                    r'\((?P<flags>[^)]*)\)\s+"(?P<delim>[^"]*)"\s+\{(\d+)\}',
                    decoded,
                )
                if m2:
                    continue  # skip literal form, handled differently per server
                continue
            flags_str = m.group("flags")
            delim = m.group("delim")
            name_utf7 = m.group("name")
            name = _decode_utf7(name_utf7)

            if "\\Noselect" in flags_str:
                continue

            skip = self.config.skip_folders
            if name in skip:
                continue

            folders.append((flags_str, delim, name))
        return folders

    # ── folder sync ─────────────────────────────────────────

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
        skip_before: str | None = None,  # noqa: ARG002
        batch_size: int = 100,
    ) -> tuple[int, int, int]:
        """Fetch new/changed messages from one folder.

        Returns (fetched_count, skipped_count, new_uid_validity).

        Calls *on_message* for each new message with:
          (raw_bytes, uid, folder_slug, eml_filename)
        The caller is responsible for writing the .eml file and DB insert.
        """
        assert self._conn is not None
        folder_slug = _slugify(folder_name)

        # ── SELECT folder ──
        status, resp = self._conn.select(folder_name, readonly=True)
        if status != "OK":
            err_raw = resp[0] if resp else b"unknown"
            err = (
                err_raw.decode("utf-8", errors="replace")
                if isinstance(err_raw, bytes)
                else str(err_raw)
            )
            raise RuntimeError(f"SELECT {folder_name!r} failed: {err}")
        data = resp

        # Parse UIDVALIDITY from SELECT response
        new_uid_validity: int | None = None
        for item in data:
            if isinstance(item, bytes) and b"UIDVALIDITY" in item:
                m = re.search(rb"UIDVALIDITY\s+(\d+)", item)
                if m:
                    new_uid_validity = int(m.group(1))
                    break
        assert new_uid_validity is not None, f"Could not determine UIDVALIDITY for {folder_name!r}"

        # ── Determine UIDs to fetch ──
        uid_validity_changed = new_uid_validity != uid_validity

        if uid_validity_changed or last_synced_uid == 0:
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
            return (0, 0, new_uid_validity)

        total = len(uid_list)
        if limit is not None:
            uid_list = uid_list[:limit]
            total = len(uid_list)

        fetched = 0
        skipped = 0

        # ── Fetch in batches ──
        for i in range(0, len(uid_list), batch_size):
            batch = uid_list[i : i + batch_size]
            batch_str = ",".join(str(uid) for uid in batch)

            status, fetch_data = self._conn.uid(
                "FETCH", batch_str, "(BODY.PEEK[] INTERNALDATE FLAGS)"
            )
            if status != "OK":
                # Retry once with smaller batch if this fails
                time.sleep(0.5)
                # Fall back to single UID fetches for the batch
                for uid in batch:
                    try:
                        f = self._conn.uid("FETCH", str(uid), "(BODY.PEEK[] INTERNALDATE FLAGS)")
                        if f[0] == "OK":
                            _process_fetch_response(
                                f[1],
                                uid,
                                folder_slug,
                                eml_dir,
                                on_message,
                            )
                            fetched += 1
                    except Exception:
                        pass
                continue

            for uid in batch:
                try:
                    ok = _process_fetch_response(
                        fetch_data,
                        uid,
                        folder_slug,
                        eml_dir,
                        on_message,
                    )
                    if ok:
                        fetched += 1
                    else:
                        skipped += 1
                except Exception:
                    skipped += 1

            if on_progress:
                on_progress(folder_name, fetched + skipped, total)

        return (fetched, skipped, new_uid_validity)


def _process_fetch_response(
    fetch_data: list[tuple],
    target_uid: int,
    folder_slug: str,
    eml_dir: Path,  # noqa: ARG001
    on_message: Callable[[bytes, int, str, str], None],
) -> bool:
    """Process a single FETCH response for one UID.

    Returns True if the message was new, False if skipped/duplicate.
    """
    # fetch_data[1] is a list of raw response tuples
    for resp_part in fetch_data[1]:
        if not isinstance(resp_part, tuple):
            continue
        raw_resp, raw_body = resp_part
        if raw_body is None or raw_body == b"":
            continue

        # Extract UID from the response line
        uid_m = re.search(rb"UID\s+(\d+)", raw_resp)
        if not uid_m:
            continue
        uid = int(uid_m.group(1))
        if uid != target_uid:
            continue

        eml_filename = f"{uid}.eml"
        on_message(raw_body, uid, folder_slug, eml_filename)
        return True
    return False
