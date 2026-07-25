#!/usr/bin/env python3
"""Build and activate a system config from the monorepo.

Reads the target path from $MONOREPO_TARGET_FILE (default /etc/monorepo-target),
builds <target>.activate via nix-build, and runs the activation script.
Works for nixos, darwin, and home-manager configs.
"""

import os
import subprocess
import sys
from pathlib import Path


def is_monorepo(candidate: Path) -> bool:
    """Check whether `candidate` looks like the dev monorepo root."""
    return (
        (candidate / "nix" / "readTree" / "default.nix").is_file()
        and (candidate / "default.nix").is_file()
    )


def resolve_root() -> Path:
    """Find the monorepo checkout, trying several strategies."""
    if root := os.environ.get("MONOREPO_ROOT"):
        cand = Path(root)
        if not cand.is_dir():
            sys.exit(f"MONOREPO_ROOT={root} is not a directory")
        return cand

    def _homedir(suffix: str) -> Path:
        return Path(os.path.expanduser(suffix))

    # Try git, then common checkout paths
    git_cand = None
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            git_cand = Path(result.stdout.strip())
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    for cand in filter(None, [git_cand, _homedir("~/dev/dev"), _homedir("~/dev")]):
        if is_monorepo(cand):
            return cand

    sys.exit(
        "could not locate monorepo\n"
        "tried: git rev-parse --show-toplevel, ~/dev/dev, ~/dev\n"
        "set MONOREPO_ROOT to the checkout path"
    )


def main() -> None:
    monorepo = resolve_root()
    target_file = Path(os.environ.get("MONOREPO_TARGET_FILE", "/etc/monorepo-target"))

    if not target_file.is_file():
        sys.exit(
            f"no target file at {target_file}\n\n"
            "create one to point at your system config:\n"
            f"  echo 'systems.configs.aviary' | sudo tee {target_file}\n\n"
            "targets are at readTree paths under systems/ and users/*/systems/"
        )

    target = target_file.read_text().strip()
    if not target:
        sys.exit(f"empty target file at {target_file}")

    attr = f"{target}.activate"
    print(f"[mono-switch] building {attr}...")
    result = subprocess.run(
        ["nix-build", "--no-out-link", str(monorepo), "-A", attr],
        capture_output=True, text=True,
    )
    # nix-build prints the store path to stdout on success
    if result.returncode != 0:
        sys.exit(result.stderr.strip() or f"nix-build failed for {attr}")

    store_path = result.stdout.strip()
    activate_bin = Path(store_path) / "bin" / "activate"
    if not activate_bin.is_file():
        sys.exit(f"activation binary not found: {activate_bin}")

    print("[mono-switch] activating...")
    os.execv(str(activate_bin), [str(activate_bin)] + sys.argv[1:])


if __name__ == "__main__":
    main()
