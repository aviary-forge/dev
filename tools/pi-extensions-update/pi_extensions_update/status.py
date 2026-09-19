"""`status`: pinned vs registry-latest vs ad-hoc-installed versions."""

from __future__ import annotations

import os
from pathlib import Path

from . import discover, registry

PI_NODE_MODULES = Path.home() / ".pi" / "agent" / "npm" / "node_modules"


def _latest(pkg: discover.Package) -> str:
    try:
        return registry.latest_version(pkg.npm_name)
    except registry.RegistryError as e:
        return f"ERR ({e})"


def run() -> int:
    packages = discover.discover(discover.repo_root())
    node_modules = Path(os.environ.get("PI_EXTENSIONS_NODE_MODULES", str(PI_NODE_MODULES)))

    headers = ("package", "pinned", "latest", "installed")
    rows = [
        (
            pkg.npm_name,
            pkg.pinned_version,
            _latest(pkg),
            discover.installed_version(node_modules, pkg.npm_name) or "-",
        )
        for pkg in packages
    ]

    widths = [
        max(len(headers[i]), *(len(row[i]) for row in rows)) if rows else len(headers[i])
        for i in range(len(headers))
    ]
    line = "  ".join(h.ljust(w) for h, w in zip(headers, widths, strict=True))
    print(line)
    print("  ".join("-" * w for w in widths))
    for row in rows:
        print("  ".join(c.ljust(w) for c, w in zip(row, widths, strict=True)))

    return 0
