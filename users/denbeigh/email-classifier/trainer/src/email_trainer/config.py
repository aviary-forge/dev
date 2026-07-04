"""Configuration for email-trainer.

Derives storage paths from the same default location as email-loader
(``~/.local/share/email-classifier/``) so no config file is required.
"""

import os
from dataclasses import dataclass, field
from pathlib import Path


@dataclass(frozen=True)
class Config:
    """Immutable configuration for the embedding/clustering pipeline.

    All paths derive from *storage_dir* by default.  Pass explicit
    paths to override individual locations.
    """

    storage_dir: str = field(default="~/.local/share/email-classifier")

    # Derived paths — overridable via constructor kwargs
    db_path: str = ""
    eml_dir: str = ""
    embeddings_dir: str = ""
    extracted_dir: str = ""
    clusters_dir: str = ""
    labels_dir: str = ""
    models_dir: str = ""

    def __post_init__(self) -> None:
        # Resolve storage_dir first so we can derive the rest.
        storage = Path(os.path.expanduser(self.storage_dir)).resolve()

        # Use object.__setattr__ because the dataclass is frozen.
        for attr, default_suffix in [
            ("db_path", "index.db"),
            ("eml_dir", "eml"),
            ("embeddings_dir", "embeddings"),
            ("extracted_dir", "extracted"),
            ("clusters_dir", "clusters"),
            ("labels_dir", "labels"),
            ("models_dir", "models"),
        ]:
            val = getattr(self, attr)
            if not val:
                resolved = (storage / default_suffix).as_posix()
                object.__setattr__(self, attr, resolved)

    @property
    def db_path_resolved(self) -> Path:
        return Path(os.path.expanduser(self.db_path)).resolve()

    @property
    def eml_dir_resolved(self) -> Path:
        return Path(os.path.expanduser(self.eml_dir)).resolve()

    @property
    def embeddings_dir_resolved(self) -> Path:
        return Path(os.path.expanduser(self.embeddings_dir)).resolve()

    @property
    def extracted_dir_resolved(self) -> Path:
        return Path(os.path.expanduser(self.extracted_dir)).resolve()

    @property
    def clusters_dir_resolved(self) -> Path:
        return Path(os.path.expanduser(self.clusters_dir)).resolve()

    @property
    def labels_dir_resolved(self) -> Path:
        return Path(os.path.expanduser(self.labels_dir)).resolve()

    @property
    def models_dir_resolved(self) -> Path:
        return Path(os.path.expanduser(self.models_dir)).resolve()
