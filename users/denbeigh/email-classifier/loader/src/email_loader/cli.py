"""CLI entry point for email-loader.

Parses arguments, orchestrates the IMAP sync, and writes results to
SQLite + .eml files.
"""

import argparse
import email.header
import email.utils
import sys
from pathlib import Path
from typing import Any

from email_loader.config import Config
from email_loader.imap_client import IMAPClient, _preview_from_message, _slugify
from email_loader.models import Database


def _decode_header(value: str | None) -> str | None:
    """Decode an RFC 2047 encoded header to plain text."""
    if not value:
        return None
    parts: list[str] = []
    for decoded, charset in email.header.decode_header(value):
        if isinstance(decoded, bytes):
            try:
                parts.append(decoded.decode(charset or "utf-8", errors="replace"))
            except LookupError:
                parts.append(decoded.decode("utf-8", errors="replace"))
        else:
            parts.append(str(decoded))
    return " ".join(parts)


def _extract_headers(raw_bytes: bytes) -> dict[str, Any]:
    """Extract useful metadata from raw email bytes.

    Returns a dict with keys: message_id, subject, from_addr, to_addrs, date.
    """
    msg = email.message_from_bytes(raw_bytes)
    return {
        "message_id": _decode_header(msg.get("Message-ID")),
        "subject": _decode_header(msg.get("Subject")),
        "from_addr": _decode_header(msg.get("From")),
        "to_addrs": _decode_header(msg.get("To")),
        "date": _fix_email_date(msg.get("Date")),
        "body_preview": _preview_from_message(msg),
    }


def _fix_email_date(date_str: str | None) -> str | None:
    """Normalize an email Date header to ISO-8601 or return None."""
    if not date_str:
        return None
    parsed = email.utils.parsedate_to_datetime(date_str)
    if parsed:
        return parsed.isoformat()
    return None


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="email-loader",
        description="Download emails from IMAP (Outlook) to local .eml files + SQLite index.",
    )
    parser.add_argument(
        "--config",
        default="./config.yaml",
        help="Path to config YAML (default: ./config.yaml)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Connect, list folders and counts, but don't download anything",
    )
    parser.add_argument(
        "--folder",
        help="Sync only this folder (e.g. 'INBOX')",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Max messages to fetch per folder (for testing)",
    )
    parser.add_argument(
        "--skip-before",
        help="Skip emails older than this date (ISO format, e.g. 2020-01-01)",
    )
    return parser.parse_args(argv)


def _progress_cb(folder: str, current: int, total: int) -> None:
    """Print a simple progress line."""
    if total > 0:
        pct = current * 100 // total
        print(f"  [{folder}] {current}/{total} ({pct}%)", file=sys.stderr)
    else:
        print(f"  [{folder}] {current} messages", file=sys.stderr)


def main(argv: list[str] | None = None) -> None:
    args = _parse_args(argv)

    # ── Load config ──
    config_path = Path(args.config)
    if not config_path.exists():
        print(f"Config file not found: {config_path}", file=sys.stderr)
        print("Create one — see cli-email-fetcher-plan.md for a template.", file=sys.stderr)
        sys.exit(1)

    config = Config.from_yaml(config_path)

    # ── Dry-run: just connect and list ──
    if args.dry_run:
        _do_dry_run(config, args)
        return

    # ── Full sync ──
    db = Database(config.storage.db_path)
    client = IMAPClient(config)

    print(f"Connecting to {config.imap.host}:{config.imap.port}...", file=sys.stderr)
    try:
        client.connect()
    except Exception as e:
        print(f"Connection failed: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        folders = client.list_folders()
        if not folders:
            print("No folders found (or all skipped).", file=sys.stderr)
            return

        if args.folder:
            matched = [f for f in folders if f[2] == args.folder]
            if not matched:
                print(f"Folder {args.folder!r} not found.", file=sys.stderr)
                sys.exit(1)
            folders = matched

        total_fetched = 0
        total_skipped = 0

        for _flags, _delim, folder_name in folders:
            print(f"\nSyncing {folder_name!r}...", file=sys.stderr)

            # Check existing folder state
            existing = db.get_folder(folder_name)
            uid_validity = existing.uid_validity if existing else 0
            last_synced_uid = existing.last_synced_uid if existing else 0

            # Upsert folder (updates uid_validity, creates if new)
            slug = _slugify(folder_name)
            folder_row = db.upsert_folder(folder_name, slug, uid_validity)

            # Create eml subdirectory
            eml_dir = config.storage.eml_dir / slug
            eml_dir.mkdir(parents=True, exist_ok=True)

            log_id = db.start_sync_log(folder_row.id)

            def on_message(
                raw_bytes: bytes,
                uid: int,
                folder_slug: str,  # noqa: ARG001
                eml_filename: str,
                _folder_row=folder_row,
                _eml_dir=eml_dir,
                _config=config,
            ) -> None:
                """Callback: write .eml and insert DB record."""
                nonlocal fetched, skipped

                if db.email_exists(_folder_row.id, uid):
                    skipped += 1
                    return

                # Write .eml file
                eml_path = _eml_dir / eml_filename
                eml_path.write_bytes(raw_bytes)

                # Extract headers
                headers = _extract_headers(raw_bytes)

                # Insert into DB
                db.insert_email(
                    _folder_row.id,
                    uid,
                    message_id=headers["message_id"],
                    subject=headers["subject"],
                    from_addr=headers["from_addr"],
                    to_addrs=headers["to_addrs"],
                    date=headers["date"],
                    flags="",
                    eml_path=str(eml_path.relative_to(_config.storage.eml_dir)),
                    size_bytes=len(raw_bytes),
                    body_preview=headers["body_preview"],
                )
                fetched += 1

            fetched = 0
            skipped = 0

            try:
                new_fetched, new_skipped, new_uid_validity = client.sync_folder(
                    folder_name,
                    uid_validity=uid_validity,
                    last_synced_uid=last_synced_uid,
                    eml_dir=eml_dir,
                    on_message=on_message,
                    on_progress=_progress_cb,
                    limit=args.limit,
                    skip_before=args.skip_before,
                )
                db.update_last_synced_uid(folder_row.id, new_uid_validity)

                # Log success
                db.finish_sync_log(
                    log_id,
                    fetched=fetched,
                    skipped=skipped,
                )

                total_fetched += fetched
                total_skipped += skipped

                print(
                    f"  ✓ {fetched} new, {skipped} skipped",
                    file=sys.stderr,
                )

            except Exception as e:
                db.finish_sync_log(log_id, error=str(e))
                print(f"  ✗ Error: {e}", file=sys.stderr)
                # Continue to next folder

        print(
            f"\nDone. {total_fetched} new emails, {total_skipped} skipped across {len(folders)} folders.",
            file=sys.stderr,
        )

    finally:
        client.disconnect()
        db.close()


def _do_dry_run(config: Config, args: argparse.Namespace) -> None:
    """Dry-run: connect, list folders, show counts — no downloads."""
    from email_loader.imap_client import IMAPClient

    client = IMAPClient(config)
    try:
        client.connect()
    except Exception as e:
        print(f"Connection failed: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        folders = client.list_folders()
        print(f"\nFound {len(folders)} folders:\n", file=sys.stderr)
        for _flags, _delim, name in folders:
            if args.folder and name != args.folder:
                continue
            print(f"  {name}", file=sys.stderr)
            # Try to get count
            try:
                status, data = client._conn.select(name, readonly=True)  # type: ignore[union-attr]
                if status == "OK":
                    count = data[0]
                    if isinstance(count, bytes):
                        print(f"    ~{count.decode()} messages", file=sys.stderr)
            except Exception:
                pass
    finally:
        client.disconnect()
