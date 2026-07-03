"""Read-only access to the loader's SQLite index.

This module queries the ``emails`` and ``folders`` tables produced by
``email-loader`` without writing to them.  No schema modifications.
"""

import dataclasses
import sqlite3
from pathlib import Path


@dataclasses.dataclass
class EmailRecord:
    """A single email row from the loader's index, enriched with absolute paths."""

    email_id: int
    folder_id: int
    uid: int
    subject: str | None
    from_addr: str | None
    folder_slug: str
    folder_name: str
    eml_path_rel: str  # relative to storage.eml_dir
    body_preview: str | None
    date: str | None

    def eml_abspath(self, base_dir: Path) -> Path:
        """Resolve the absolute path given the eml root directory."""
        return base_dir / self.eml_path_rel


_EMAIL_QUERY = """
    SELECT
        e.id          AS email_id,
        e.folder_id   AS folder_id,
        e.uid         AS uid,
        e.subject     AS subject,
        e.from_addr   AS from_addr,
        f.slug        AS folder_slug,
        f.name        AS folder_name,
        e.eml_path    AS eml_path_rel,
        e.body_preview AS body_preview,
        e.date        AS date
    FROM emails e
    JOIN folders f ON f.id = e.folder_id
"""


class Database:
    """Read-only wrapper around the loader's SQLite index."""

    def __init__(self, db_path: str | Path) -> None:
        self.db_path = Path(db_path)
        self.conn = sqlite3.connect(str(self.db_path))
        self.conn.row_factory = sqlite3.Row

    def close(self) -> None:
        self.conn.close()

    def list_emails(
        self,
        folder_slug: str | None = None,
        limit: int | None = None,
    ) -> list[EmailRecord]:
        """Return all (or filtered) email records.

        Args:
            folder_slug: If given, only return emails in this folder.
            limit: Max rows to return (useful for testing).

        Returns:
            A list of ``EmailRecord`` instances.
        """
        query = _EMAIL_QUERY
        params: list = []

        if folder_slug:
            query += " WHERE f.slug = ?"
            params.append(folder_slug)

        query += " ORDER BY e.date NULLS LAST, e.id"

        if limit is not None:
            query += " LIMIT ?"
            params.append(limit)

        rows = self.conn.execute(query, params).fetchall()
        return [EmailRecord(**dict(r)) for r in rows]

    def email_exists(self, email_id: int) -> bool:
        """Return True if *email_id* has already been processed.

        Checks against the output (extracted) table — once Phase 1
        processing is committed.  For now, a stub that checks the
        primary emails table always returns True for any existing row.
        """
        row = self.conn.execute(
            "SELECT 1 FROM emails WHERE id = ?",
            (email_id,),
        ).fetchone()
        return row is not None
