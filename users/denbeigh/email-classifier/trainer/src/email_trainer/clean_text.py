"""Extract clean text from .eml files for embedding.

Implements Phase 1 extraction rules from ``EMBEDDING-PIPELINE-PLAN.md``:

1. Walk MIME parts via stdlib ``email`` module.
2. Prefer ``text/plain`` parts. Fall back to ``text/html`` rendered via
   ``html2text``.
3. Strip quoted replies (``On <date> wrote:``, ``--- Original Message ---``,
   ``>``-prefixed lines, forward separator).
4. Drop signature block after ``-- \\n`` delimiter.
5. Concatenate ``from_addr | subject`` + cleaned body.
6. Truncate to 6000 chars.
"""

import email.message
import email.parser
import re
from pathlib import Path

import html2text

# ── quoted-reply detection patterns ─────────────────────────

_QUOTED_SEPARATORS: list[str] = [
    r"On\s+.+\s+wrote:",  # "On Mon, 1 Jan 2024 at 12:00, John wrote:"
    r"-{3,}\s*Original\s+Message\s*-{3,}",  # "--- Original Message ---"
    r"-{3,}\s*Forwarded\s+message\s*-{3,}",  # "--- Forwarded message ---"
]

# Compiled regex that matches any of the above as a full line.
_QUOTED_RE = re.compile(
    r"^\s*(?:" + "|".join(_QUOTED_SEPARATORS) + r")\s*$",
    re.IGNORECASE | re.MULTILINE,
)

# Lines starting with ">" (possibly after whitespace) are quoted text.
_QUOTED_LINE_RE = re.compile(r"^[>\u00BB]")


def _strip_quoted_replies(text: str) -> str:
    """Strip quoted reply sections from *text*.

    Drops everything after a quoted-reply separator line.  Also drops
    individual ``>``-prefixed lines that appear before the separator
    (e.g. inline quoted fragments).
    """
    # First, drop >-prefixed lines entirely (they're quoted text).
    lines = text.splitlines()
    clean_lines = [line for line in lines if not _QUOTED_LINE_RE.match(line)]
    text = "\n".join(clean_lines)

    # Then truncate at the first quoted-reply separator.
    match = _QUOTED_RE.search(text)
    if match:
        text = text[: match.start()]

    return text


def _strip_signature(text: str) -> str:
    """Strip the signature block starting with ``-- `` on its own line."""
    # The standard signature delimiter is "-- " at the start of a line.
    sig_re = re.compile(r"^-- \s*$", re.MULTILINE)
    match = sig_re.search(text)
    if match:
        text = text[: match.start()]
    return text


def _render_html_to_text(html: str) -> str:
    """Convert HTML to readable plain text via html2text."""
    h = html2text.HTML2Text()
    h.body_width = 0  # no line wrapping
    h.ignore_links = False
    h.ignore_images = True
    h.ignore_emphasis = False
    h.protect_links = False
    h.unicode_snob = True
    # Skip style/script blocks automatically handled by html2text.
    return h.handle(html)


def _extract_body_from_msg(msg: email.message.Message) -> str:
    """Walk MIME parts and return the best plain-text body.

    Prefers ``text/plain``.  Falls back to ``text/html`` rendered via
    ``html2text``.  Returns empty string if no usable body is found.
    """
    body: str | None = None
    html_body: str | None = None

    for part in msg.walk():
        content_type = part.get_content_type()
        payload = part.get_payload(decode=True)
        if not isinstance(payload, bytes):
            continue

        try:
            charset = part.get_content_charset() or "utf-8"
            decoded = payload.decode(charset, errors="replace")
        except (LookupError, UnicodeDecodeError):
            decoded = payload.decode("utf-8", errors="replace")

        if content_type == "text/plain":
            body = decoded
            break  # prefer the first text/plain part
        elif content_type == "text/html" and html_body is None:
            html_body = decoded

    if body is not None:
        return body
    if html_body is not None:
        return _render_html_to_text(html_body)

    # Last resort: any text/* part
    for part in msg.walk():
        if part.get_content_maintype() == "text":
            payload = part.get_payload(decode=True)
            if payload:
                try:
                    return payload.decode("utf-8", errors="replace")
                except UnicodeDecodeError:
                    return payload.decode("latin-1", errors="replace")

    return ""


def clean_email_text(
    eml_abs_path: Path,
    subject: str | None,
    from_addr: str | None,
    *,
    body_preview: str | None = None,
    use_preview: bool = False,
    max_chars: int = 6000,
) -> str:
    """Extract clean text from a single .eml file for embedding.

    Args:
        eml_abs_path: Absolute path to the ``.eml`` file.
        subject: Email subject line (may be ``None``).
        from_addr: Sender email address (may be ``None``).
        body_preview: Short preview text from the loader's DB (only used
            when *use_preview* is ``True``).
        use_preview: When ``True``, skip MIME parsing and use
            ``body_preview`` from the DB instead.  Useful as a fast
            first pass — switch to full MIME parsing if clustering
            quality suffers.
        max_chars: Maximum character length for the returned text
            (default 6000, safely under the 8192 token model limit).

    Returns:
        A single string: ``from_addr | subject  cleaned_body``
        (or a subset if truncated).
    """
    # ── v1 shortcut: use body_preview from DB ──
    if use_preview:
        body = body_preview or ""
    else:
        # ── Full MIME walk ──
        try:
            with open(eml_abs_path, "rb") as f:
                msg = email.message_from_binary_file(f)
        except (FileNotFoundError, PermissionError):
            # If the .eml file is missing, fall back to body_preview.
            body = body_preview or ""
        else:
            body = _extract_body_from_msg(msg)

    # ── Clean the body ──
    body = _strip_quoted_replies(body)
    body = _strip_signature(body)
    body = re.sub(r"\s+", " ", body).strip()

    # ── Build the text vector ──
    prefix_parts = [p for p in (from_addr, subject) if p]
    prefix = " | ".join(prefix_parts)
    if prefix and body:
        text = f"{prefix} {body}"
    elif prefix:
        text = prefix
    else:
        text = body

    # ── Truncate ──
    if len(text) > max_chars:
        text = text[:max_chars].rsplit(" ", 1)[0]  # cut at word boundary

    return text
