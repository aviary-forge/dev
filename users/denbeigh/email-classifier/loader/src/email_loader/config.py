"""Configuration loading and validation for email-loader."""

import dataclasses
import os
from pathlib import Path
from typing import Self

import yaml


@dataclasses.dataclass(frozen=True)
class OAuth2Config:
    """OAuth2 configuration for Microsoft Identity Platform (Entra ID)."""

    client_id: str = ""
    client_secret: str = ""
    tenant_id: str = ""

    @property
    def authority(self) -> str:
        return f"https://login.microsoftonline.com/{self.tenant_id or 'common'}"

    @property
    def imap_scopes(self) -> list[str]:
        # IMAP app-only (client credentials) requests a token for Exchange
        # Online; /.default resolves to whatever app permissions are granted
        # on the app reg for this resource (e.g. IMAP.AccessAsApp).
        return ["https://outlook.office365.com/.default"]


@dataclasses.dataclass(frozen=True)
class IMAPConfig:
    host: str = "outlook.office365.com"
    port: int = 993
    username: str = ""
    password: str = ""  # fallback for non-OAuth2 IMAP login
    oauth2: OAuth2Config = dataclasses.field(default_factory=OAuth2Config)


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

        oauth2_data = imap_data.get("oauth2", {})

        return cls(
            imap=IMAPConfig(
                host=imap_data.get("host", "outlook.office365.com"),
                port=imap_data.get("port", 993),
                username=imap_data.get("username", ""),
                password=imap_data.get("password", ""),
                oauth2=OAuth2Config(
                    client_id=oauth2_data.get("client_id", ""),
                    client_secret=oauth2_data.get("client_secret", ""),
                    tenant_id=oauth2_data.get("tenant_id", ""),
                ),
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
