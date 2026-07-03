"""SQLite data access layer for email-loader.

Manages folders, emails, and sync_log tables with idempotent schema init.
"""

import dataclasses
import datetime
import sqlite3
from pathlib import Path


@dataclasses.dataclass
class FolderRow:
    id: int = 0
    name: str = ""
    slug: str = ""
    uid_validity: int = 0
    last_synced_uid: int = 0


@dataclasses.dataclass
class EmailRow:
    id: int = 0
    folder_id: int = 0
    uid: int = 0
    message_id: str | None = None
    subject: str | None = None
    from_addr: str | None = None
    to_addrs: str | None = None
    date: str | None = None
    flags: str | None = None
    eml_path: str = ""
    size_bytes: int = 0
    body_preview: str | None = None
    imported_at: str = ""


SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS folders (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    slug TEXT NOT NULL UNIQUE,
    uid_validity INTEGER NOT NULL,
    last_synced_uid INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS emails (
    id INTEGER PRIMARY KEY,
    folder_id INTEGER NOT NULL REFERENCES folders(id),
    uid INTEGER NOT NULL,
    message_id TEXT,
    subject TEXT,
    from_addr TEXT,
    to_addrs TEXT,
    date TIMESTAMP,
    flags TEXT,
    eml_path TEXT NOT NULL,
    size_bytes INTEGER DEFAULT 0,
    body_preview TEXT,
    imported_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(folder_id, uid)
);

CREATE INDEX IF NOT EXISTS idx_emails_folder_uid ON emails(folder_id, uid);
CREATE INDEX IF NOT EXISTS idx_emails_message_id ON emails(message_id);
CREATE INDEX IF NOT EXISTS idx_emails_date ON emails(date);

CREATE TABLE IF NOT EXISTS sync_log (
    id INTEGER PRIMARY KEY,
    folder_id INTEGER NOT NULL REFERENCES folders(id),
    started_at TIMESTAMP,
    completed_at TIMESTAMP,
    messages_fetched INTEGER DEFAULT 0,
    messages_skipped INTEGER DEFAULT 0,
    error TEXT
);
"""


class Database:
    """Wraps a SQLite connection with email-loader's schema and queries."""

    def __init__(self, db_path: str | Path) -> None:
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(str(self.db_path))
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA foreign_keys=ON")
        self._init_schema()

    def _init_schema(self) -> None:
        self.conn.executescript(SCHEMA_SQL)
        self.conn.commit()

    def close(self) -> None:
        self.conn.close()

    # ── folders ──────────────────────────────────────────────

    def get_folder(self, name: str) -> FolderRow | None:
        row = self.conn.execute(
            "SELECT id, name, slug, uid_validity, last_synced_uid FROM folders WHERE name = ?",
            (name,),
        ).fetchone()
        if row is None:
            return None
        return FolderRow(*row)

    def upsert_folder(self, name: str, slug: str, uid_validity: int) -> FolderRow:
        self.conn.execute(
            """INSERT INTO folders (name, slug, uid_validity)
               VALUES (?, ?, ?)
               ON CONFLICT(name) DO UPDATE SET
                 slug = excluded.slug,
                 uid_validity = excluded.uid_validity""",
            (name, slug, uid_validity),
        )
        self.conn.commit()
        row = self.get_folder(name)
        assert row is not None
        return row

    def update_last_synced_uid(self, folder_id: int, uid: int) -> None:
        """Update the ``last_synced_uid`` column for *folder_id*."""
        self.conn.execute(
            "UPDATE folders SET last_synced_uid = ? WHERE id = ?",
            (uid, folder_id),
        )
        self.conn.commit()

    def update_folder_sync_state(
        self, folder_id: int, uid_validity: int, last_synced_uid: int
    ) -> None:
        """Update both ``uid_validity`` and ``last_synced_uid`` after a sync."""
        self.conn.execute(
            "UPDATE folders SET uid_validity = ?, last_synced_uid = ? WHERE id = ?",
            (uid_validity, last_synced_uid, folder_id),
        )
        self.conn.commit()

    def list_folders(self) -> list[FolderRow]:
        rows = self.conn.execute(
            "SELECT id, name, slug, uid_validity, last_synced_uid FROM folders ORDER BY name"
        ).fetchall()
        return [FolderRow(*r) for r in rows]

    # ── emails ───────────────────────────────────────────────

    def email_exists(self, folder_id: int, uid: int) -> bool:
        row = self.conn.execute(
            "SELECT 1 FROM emails WHERE folder_id = ? AND uid = ?",
            (folder_id, uid),
        ).fetchone()
        return row is not None

    def insert_email(
        self,
        folder_id: int,
        uid: int,
        *,
        message_id: str | None = None,
        subject: str | None = None,
        from_addr: str | None = None,
        to_addrs: str | None = None,
        date: str | None = None,
        flags: str | None = None,
        eml_path: str,
        size_bytes: int = 0,
        body_preview: str | None = None,
    ) -> None:
        self.conn.execute(
            """INSERT OR IGNORE INTO emails
               (folder_id, uid, message_id, subject, from_addr, to_addrs,
                date, flags, eml_path, size_bytes, body_preview)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                folder_id,
                uid,
                message_id,
                subject,
                from_addr,
                to_addrs,
                date,
                flags,
                eml_path,
                size_bytes,
                body_preview,
            ),
        )
        self.conn.commit()

    # ── sync_log ─────────────────────────────────────────────

    def start_sync_log(self, folder_id: int) -> int:
        cur = self.conn.execute(
            "INSERT INTO sync_log (folder_id, started_at) VALUES (?, ?)",
            (folder_id, datetime.datetime.now(datetime.UTC).isoformat()),
        )
        self.conn.commit()
        rowid = cur.lastrowid
        assert rowid is not None, "lastrowid should not be None after INSERT"
        return rowid

    def finish_sync_log(
        self,
        log_id: int,
        fetched: int = 0,
        skipped: int = 0,
        error: str | None = None,
    ) -> None:
        self.conn.execute(
            """UPDATE sync_log SET
               completed_at = ?,
               messages_fetched = ?,
               messages_skipped = ?,
               error = ?
               WHERE id = ?""",
            (
                datetime.datetime.now(datetime.UTC).isoformat(),
                fetched,
                skipped,
                error,
                log_id,
            ),
        )
        self.conn.commit()
