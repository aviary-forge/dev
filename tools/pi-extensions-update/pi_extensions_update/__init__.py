"""pi-extensions-update: manage nix-packaged pi extensions.

Discovers packages under ``third_party/pi-extensions`` (dirs whose
``default.nix`` calls ``mkPiPackage`` with an entry in ``versions.json``),
reads/writes their pins, and drives the version/srcHash/npmDepsHash bump
pipeline against the npm registry.

Design + validated mechanics: ``docs/pi-extensions-update-tool.md``.
"""

__version__ = "0.1.0"
