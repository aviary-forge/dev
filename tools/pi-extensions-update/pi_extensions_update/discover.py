"""Discovery + parsing of nix-packaged pi extensions.

A package is a subdirectory of ``third_party/pi-extensions`` whose
``default.nix`` calls ``mkPiPackage`` and which has an entry in
``versions.json`` (keyed by npm name) — which excludes pi-coding-agent-host,
the wrapped host agent.

All ``default.nix`` parsing is line-anchored within the ``mkPiPackage { ... }``
call region (first occurrence to end of file) and fails loudly on zero or
multiple matches. Global uniqueness of hash lines is luck, not contract.
"""

from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

PI_EXTENSIONS_SUBDIR = Path("third_party") / "pi-extensions"

# Mirror of //nix/mkPiPackage's tarballUrl: the basename strips the
# @scope/ prefix (e.g. @ayulab/pi-rewind -> pi-rewind-<version>.tgz).
REGISTRY_URL = "https://registry.npmjs.org"


class ParseError(Exception):
    """A package default.nix could not be parsed unambiguously."""


@dataclass(frozen=True)
class Package:
    """One mkPiPackage package, with its pinned state as-parsed."""

    dir_name: str
    pname: str
    npm_name: str
    src_hash: str
    npm_deps_hash: str
    default_nix: Path
    pinned_version: str

    @property
    def tarball_basename(self) -> str:
        """Tarball filename per mkPiPackage's tarballUrl: scope stripped."""
        return f"{self.npm_name.rsplit('/', 1)[-1]}-{self.pinned_version}.tgz"

    def tarball_url(self) -> str:
        base = self.npm_name.rsplit("/", 1)[-1]
        return f"{REGISTRY_URL}/{self.npm_name}/-/{base}-{self.pinned_version}.tgz"


@dataclass(frozen=True)
class NixAttrs:
    """Attributes parsed from one default.nix."""

    pname: str
    npm_name: str
    src_hash: str
    npm_deps_hash: str


def repo_root() -> Path:
    """Locate the monorepo root via git (the tool is wrapped with git on PATH)."""
    out = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=True,
    )
    return Path(out.stdout.strip())


def packages_dir(root: Path) -> Path:
    return root / PI_EXTENSIONS_SUBDIR


def _match_one(pattern: re.Pattern[str], region: str, what: str, path: Path) -> str:
    matches = pattern.findall(region)
    if len(matches) == 0:
        raise ParseError(f"{path}: no {what} found in mkPiPackage block")
    if len(matches) > 1:
        raise ParseError(f"{path}: {what} matches {len(matches)} times, expected 1")
    return matches[0]


def parse_default_nix(text: str, path: Path) -> NixAttrs | None:
    """Parse pname/npmName/srcHash/npmDepsHash from a mkPiPackage default.nix.

    Returns None for files that do not call mkPiPackage (e.g. the host agent);
    each attribute must match exactly once within the call block, else
    ParseError.
    """
    idx = text.find("mkPiPackage")
    if idx < 0:
        return None
    region = text[idx:]

    pname = _match_one(_attr_re("pname"), region, "pname", path)
    npm_name_match = _attr_re("npmName").search(region)
    npm_name = npm_name_match.group(1) if npm_name_match else pname

    return NixAttrs(
        pname=pname,
        npm_name=npm_name,
        src_hash=_match_one(_attr_re("srcHash"), region, "srcHash", path),
        npm_deps_hash=_match_one(_attr_re("npmDepsHash"), region, "npmDepsHash", path),
    )


def _attr_re(attr: str) -> re.Pattern[str]:
    return re.compile(rf'^\s*{attr}\s*=\s*"([^"]+)"', re.MULTILINE)


def load_versions(path: Path) -> dict[str, str]:
    """Load versions.json: npm name -> pinned version."""
    return json.loads(path.read_text())


def discover(root: Path) -> list[Package]:
    """Find every mkPiPackage package with a versions.json entry, sorted by dir."""
    base = packages_dir(root)
    versions = load_versions(base / "versions.json")

    packages: list[Package] = []
    for entry in sorted(base.iterdir()):
        if not entry.is_dir():
            continue
        default_nix = entry / "default.nix"
        if not default_nix.exists():
            continue
        attrs = parse_default_nix(default_nix.read_text(), default_nix)
        if attrs is None or attrs.npm_name not in versions:
            # Not a package (host agent) or no versions.json entry: skip.
            continue
        packages.append(
            Package(
                dir_name=entry.name,
                pname=attrs.pname,
                npm_name=attrs.npm_name,
                src_hash=attrs.src_hash,
                npm_deps_hash=attrs.npm_deps_hash,
                default_nix=default_nix,
                pinned_version=versions[attrs.npm_name],
            )
        )
    return packages


def installed_version(node_modules: Path, npm_name: str) -> str | None:
    """Version ad-hoc-installed under ~/.pi/agent/npm/node_modules, or None.

    Scoped names map to nested directories (node_modules/@scope/name).
    """
    manifest = node_modules.joinpath(*npm_name.split("/"), "package.json")
    try:
        return str(json.loads(manifest.read_text())["version"])
    except (OSError, KeyError, ValueError):
        return None
