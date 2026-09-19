"""`check`: CI-able staleness gate.

Exit codes:
  0 — every package's pin matches the reference
  1 — at least one package is stale (pin differs from the reference)
  2 — the check itself could not run for a package (registry failure,
      discovery/versions.json problems); a partial failure must not
      masquerade as clean, and must not be reported as merely stale

`--against=installed` compares pins to the ad-hoc installs under
~/.pi/agent/npm/node_modules; a missing install counts as stale with a
distinct message, not as a check error.
"""

from __future__ import annotations

import os
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from . import discover, registry

PI_NODE_MODULES = Path.home() / ".pi" / "agent" / "npm" / "node_modules"


@dataclass(frozen=True)
class Stale:
    npm_name: str
    pinned: str
    reference: str


@dataclass(frozen=True)
class CheckFailure:
    """One package whose staleness could not be determined."""

    npm_name: str
    reason: str


def collect(
    against: str,
    packages: list[discover.Package],
    node_modules: Path,
    latest_fn: Callable[[str], str] = registry.latest_version,
) -> tuple[list[Stale], list[CheckFailure]]:
    """Compare every pin against the reference, without printing.

    latest_fn is injectable so tests never touch the network.
    """
    stales: list[Stale] = []
    failures: list[CheckFailure] = []
    for pkg in packages:
        if against == "installed":
            reference = discover.installed_version(node_modules, pkg.npm_name)
            if reference is None:
                stales.append(Stale(pkg.npm_name, pkg.pinned_version, "<not installed>"))
                continue
        else:
            try:
                reference = latest_fn(pkg.npm_name)
            except registry.RegistryError as e:
                failures.append(CheckFailure(pkg.npm_name, str(e)))
                continue
        if reference != pkg.pinned_version:
            stales.append(Stale(pkg.npm_name, pkg.pinned_version, reference))
    return stales, failures


def exit_code(stales: list[Stale], failures: list[CheckFailure]) -> int:
    """Failure (2) outranks stale (1), which outranks clean (0)."""
    if failures:
        return 2
    if stales:
        return 1
    return 0


def run(args) -> int:
    try:
        packages = discover.discover(discover.repo_root())
    except (discover.ParseError, OSError, ValueError) as e:
        # ValueError covers json.JSONDecodeError from an unreadable
        # versions.json; these are check-environment failures, not staleness.
        print(f"check: cannot enumerate packages: {e}", file=sys.stderr)
        return 2

    node_modules = Path(os.environ.get("PI_EXTENSIONS_NODE_MODULES", str(PI_NODE_MODULES)))
    stales, failures = collect(args.against, packages, node_modules)

    for s in stales:
        print(f"STALE  {s.npm_name}: pinned {s.pinned}, {args.against}: {s.reference}")
    for f in failures:
        print(f"ERROR  {f.npm_name}: {f.reason}", file=sys.stderr)

    code = exit_code(stales, failures)
    if code == 2:
        print(f"check: {len(failures)} package(s) could not be checked", file=sys.stderr)
    elif code == 1:
        print(f"check: {len(stales)}/{len(packages)} package(s) stale (against={args.against})")
    else:
        print(f"check: all {len(packages)} package(s) up to date (against={args.against})")
    return code
