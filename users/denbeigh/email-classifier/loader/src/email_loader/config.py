"""Configuration loading and validation for email-loader."""

import dataclasses
import os
from pathlib import Path
from typing import Self

import yaml


@dataclasses.dataclass(frozen=True)
class IMAPConfig:
    host: str = "outlook.office365.com"
    port: int = 993
    username: str = ""
    app_password: str = ""


@dataclasses.dataclass(frozen=True)
class StorageConfig:
    dir: str = "~/.local/share/email-classifier"

    @property
    def expanded_dir(self) -> Path:
        return Path(os.path.expanduser(self.dir)).resolve()

    @property
    def eml_dir(self) -> Path:
        return self.expanded_dir / "eml"

    @property
    def db_path(self) -> Path:
        return self.expanded_dir / "index.db"


@dataclasses.dataclass(frozen=True)
class Config:
    imap: IMAPConfig
    storage: StorageConfig
    skip_folders: tuple[str, ...] = (
        "Deleted Items",
        "Junk Email",
        "Drafts",
        "Junk",
        "Trash",
        "[Gmail]/Trash",
        "[Gmail]/Spam",
    )
    skip_before: str | None = None

    @classmethod
    def from_dict(cls, d: dict) -> Self:
        imap_data = d.get("imap", {})
        storage_data = d.get("storage", {})

        skip_before = d.get("skip_before")
        if skip_before is not None:
            skip_before = str(skip_before)

        return cls(
            imap=IMAPConfig(
                host=imap_data.get("host", "outlook.office365.com"),
                port=imap_data.get("port", 993),
                username=imap_data.get("username", ""),
                app_password=imap_data.get("app_password", ""),
            ),
            storage=StorageConfig(
                dir=storage_data.get("dir", "~/.local/share/email-classifier"),
            ),
            skip_folders=tuple(d.get("skip_folders", cls.skip_folders)),
            skip_before=skip_before,
        )

    @classmethod
    def from_yaml(cls, path: str | Path) -> Self:
        path = Path(path)
        with open(path) as f:
            raw = yaml.safe_load(f)
        if not isinstance(raw, dict):
            raise ValueError(f"Config file {path} must contain a YAML mapping")
        return cls.from_dict(raw)
