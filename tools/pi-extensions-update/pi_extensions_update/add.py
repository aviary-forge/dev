"""`add`: onboard a new npm package as a nix-packaged pi extension.

Creates <dir>/default.nix from the shipped package template, vendors a
regenerated lockfile (with the npm 11.x integrity fixup), computes srcHash +
npmDepsHash via the same machinery as `update`, and appends the pin to
versions.json. The package-specific comment block (runtime deps, lifecycle
scripts, quirks) is a TODO(human) placeholder: the tool cannot infer it.
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

from . import discover, registry, update
from .discover import Package, packages_dir
from .update import UpdateError, log

TEMPLATE_PATH = Path(__file__).parent / "package-template.nix.in"


class AddError(UpdateError):
    """The package could not be added."""


def derive_dir_name(npm_name: str, override: str | None) -> str:
    """Directory name (readTree key): --dir, or the npm name minus @scope/."""
    if override:
        return override
    return npm_name.rsplit("/", 1)[-1]


def check_collision(base: Path, versions: dict[str, str], npm_name: str, dir_name: str) -> None:
    """Refuse loudly if the npm name or the derived dir already exists."""
    if npm_name in versions:
        raise AddError(f"{npm_name} is already pinned in versions.json ({versions[npm_name]})")
    if (base / dir_name).exists():
        raise AddError(f"third_party/pi-extensions/{dir_name} already exists")


def render_template(
    npm_name: str,
    dir_name: str,
    src_hash: str,
    npm_deps_hash: str,
) -> str:
    """Instantiate package-template.nix.in.

    The quoted `versions."<npm-name>"` attr form works for both scoped and
    plain names; npmName is emitted only when it differs from pname.
    """
    text = TEMPLATE_PATH.read_text()
    npm_name_attr = f'  npmName = "{npm_name}";\n' if npm_name != dir_name else ""
    for token, value in {
        "@@NPM_NAME_ATTR@@": npm_name_attr,
        "@@NPM_NAME@@": npm_name,
        "@@PNAME@@": dir_name,
        "@@SRC_HASH@@": src_hash,
        "@@NPM_DEPS_HASH@@": npm_deps_hash,
    }.items():
        text = text.replace(token, value)
    return text


def add_package(
    npm_name: str,
    dir_name: str,
    version: str,
    root: Path,
    do_build: bool,
) -> None:
    """Run the add pipeline. Raises UpdateError on failure; the working tree
    is left dirty for inspection (git is the undo)."""
    base = packages_dir(root)
    target = base / dir_name

    with tempfile.TemporaryDirectory(prefix="piext-add-") as tmp:
        work_dir = Path(tmp)
        tarball = update.download_tarball(npm_name, version, work_dir)
        src_hash = update.hash_tarball(tarball)
        log(f"  srcHash: {src_hash}")

        default_nix = target / "default.nix"
        # npmDepsHash is filled in by resolve_npm_deps_hash below; the
        # placeholder must be a non-empty quoted string for rewrite_attr.
        default_nix.write_text(render_template(npm_name, dir_name, src_hash, "PLACEHOLDER"))
        attrs = discover.parse_default_nix(default_nix.read_text(), default_nix)
        if attrs is None:
            raise AddError(f"{default_nix}: generated template does not call mkPiPackage")

        lockfile = update.regenerate_lockfile(tarball, target, work_dir)
        pkg = Package(
            dir_name=dir_name,
            pname=attrs.pname,
            npm_name=attrs.npm_name,
            src_hash=src_hash,
            npm_deps_hash="",
            default_nix=default_nix,
            pinned_version=version,
        )
        # The pin must exist before the verify build: default.nix evaluates
        # versions.json (same ordering as update_package).
        update.write_versions(base, npm_name, version)
        update.resolve_npm_deps_hash(pkg, root, lockfile, do_build, log)

    if do_build:
        log(f"  verify build: OK ({dir_name})")


def run(args: argparse.Namespace) -> int:
    root = discover.repo_root()
    base = packages_dir(root)
    try:
        update.dirty_guard(root)
        versions = json.loads((base / "versions.json").read_text())
        dir_name = derive_dir_name(args.npm_name, args.dir)
        check_collision(base, versions, args.npm_name, dir_name)
        version = registry.resolve_version(args.npm_name, args.version)
        target = base / dir_name
        target.mkdir()
    except (AddError, UpdateError, registry.RegistryError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    try:
        add_package(args.npm_name, dir_name, version, root, do_build=not args.no_build)
    except (AddError, UpdateError, registry.RegistryError) as e:
        print(f"== {dir_name}: FAILED: {e}", file=sys.stderr)
        print("the tree is left dirty for inspection; git is the undo", file=sys.stderr)
        return 1

    print()
    print("created:")
    print(f"  third_party/pi-extensions/{dir_name}/default.nix")
    print(f"  third_party/pi-extensions/{dir_name}/package-lock.json")
    print(f'  versions.json["{args.npm_name}"] = "{version}"')
    print()
    print("next manual step: fill in the TODO(human) comment block in default.nix")
    print("(runtime deps, lifecycle scripts, quirks — the tool cannot infer them).")
    print("To deploy, add the package to myPackages in your pi home-manager config.")
    return 0
