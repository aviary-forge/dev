"""`update`: the per-package bump pipeline.

Implements docs/pi-extensions-update-tool.md "Per-package update algorithm":
registry resolve -> tarball srcHash -> lockfile regen -> pin writes ->
npmDepsHash (prefetch-npm-deps primary, fake-hash loop fallback) -> verify
build. One package at a time; a batch failure never aborts the rest.

Runtime externals (`git`, `nix`, `npm`, `prefetch-npm-deps`) are resolved
from PATH. The nix-packaged binary wraps these from the repo-pinned
nixpkgs; for ad-hoc runs, put the pinned tools on PATH yourself.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from collections.abc import Callable
from pathlib import Path

from . import discover, registry
from .discover import Package, packages_dir

FAKE_HASH = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
GOT_HASH_RE = re.compile(r"got:\s+(sha256-[A-Za-z0-9+/=]+)")
HASH_RE = re.compile(r"sha256-[A-Za-z0-9+/=]+")

# Some pinned default.nix files carry a stale comment claiming the srcHash
# came from the registry's dist.integrity (sha512). Correct it opportunistically.
OLD_SRC_COMMENT = "# sha512 of the npm tarball, from registry.npmjs.org dist.integrity"
NEW_SRC_COMMENT = "# sha256 of the npm tarball (`nix hash file --type sha256 --base64`)"


class UpdateError(Exception):
    """One step of the bump pipeline failed for a package."""


def _run(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    timeout: int = 600,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run a command, merging stderr into stdout (nix/npm log there)."""
    return subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def log(msg: str) -> None:
    print(msg, flush=True)


def _shutil_which(tool: str) -> str:
    found = shutil.which(tool)
    if found is None:
        raise UpdateError(f"{tool!r} not found on PATH (wrapped binary provides it)")
    return found


# --- pin file edits -------------------------------------------------------


def rewrite_attr(path: Path, attr: str, value: str) -> None:
    """Rewrite `attr = "..."` inside the mkPiPackage block, exactly once."""
    text = path.read_text()
    idx = text.find("mkPiPackage")
    if idx < 0:
        raise UpdateError(f"{path}: does not call mkPiPackage")
    pattern = re.compile(rf'(?m)^(\s*{attr}\s*=\s*)"[^"]+"')
    matches = pattern.findall(text[idx:])
    if len(matches) != 1:
        raise UpdateError(f"{path}: {attr} matches {len(matches)} times, expected 1")
    new_region, n = pattern.subn(rf'\g<1>"{value}"', text[idx:], count=1)
    assert n == 1
    path.write_text(text[:idx] + new_region)


def fix_src_comment(path: Path) -> None:
    """Replace the stale dist.integrity comment next to srcHash, if present."""
    text = path.read_text()
    if OLD_SRC_COMMENT in text:
        path.write_text(text.replace(OLD_SRC_COMMENT, NEW_SRC_COMMENT))


def write_versions(base: Path, npm_name: str, version: str) -> None:
    """Set one entry in versions.json, preserving 2-space indentation."""
    path = base / "versions.json"
    versions = json.loads(path.read_text())
    versions[npm_name] = version
    path.write_text(json.dumps(versions, indent=2) + "\n")


# --- pipeline steps --------------------------------------------------------


def download_tarball(npm_name: str, version: str, dest_dir: Path) -> Path:
    """Download the registry tarball (mirror of mkPiPackage's tarballUrl)."""
    base = npm_name.rsplit("/", 1)[-1]
    url = f"{registry.REGISTRY}/{npm_name}/-/{base}-{version}.tgz"
    dest = dest_dir / f"{base}-{version}.tgz"
    try:
        urllib.request.urlretrieve(url, dest)
    except OSError as e:
        raise UpdateError(f"failed to download {url}: {e}") from e
    return dest


def hash_tarball(tarball: Path) -> str:
    """srcHash: `nix hash file --type sha256 --base64` (NOT dist.integrity,
    which is sha512 for these packages)."""
    nix = _shutil_which("nix")
    proc = _run([nix, "hash", "file", "--type", "sha256", "--base64", str(tarball)])
    if proc.returncode != 0:
        raise UpdateError(f"nix hash file failed: {proc.stderr.strip()}")
    raw = proc.stdout.strip()
    # nix prints bare base64 for --type sha256; the pinned srcHash is SRI form.
    hash_value = raw if raw.startswith("sha256-") else f"sha256-{raw}"
    if not HASH_RE.fullmatch(hash_value):
        raise UpdateError(f"unexpected nix hash output: {raw!r}")
    return hash_value


def regenerate_lockfile(tarball: Path, target_dir: Path, work_dir: Path) -> Path:
    """Re-vendor package-lock.json into target_dir from the tarball's deps.

    The npm tarballs ship no lockfile; the vendored one is generated with
    --omit=peer (peers recorded as dev is load-bearing for mkPiPackage's
    npmInstallFlags). npm must be the nixpkgs-pinned one (PATH).
    """
    npm = _shutil_which("npm")
    extract_dir = work_dir / "extract"
    extract_dir.mkdir()
    with tarfile.open(tarball) as tf:
        tf.extractall(extract_dir, filter="data")
    pkg_dir = extract_dir / "package"
    if not pkg_dir.is_dir():
        raise UpdateError(f"tarball has no package/ root: {tarball}")

    proc = _run(
        [npm, "install", "--package-lock-only", "--lockfile-version", "3", "--omit=peer"],
        cwd=pkg_dir,
        timeout=1200,
    )
    if proc.returncode != 0:
        raise UpdateError(f"npm lockfile regen failed: {proc.stderr.strip()[-2000:]}")
    lockfile = pkg_dir / "package-lock.json"
    if not lockfile.exists():
        raise UpdateError("npm produced no package-lock.json")

    fixed = fix_missing_integrity(lockfile)
    if fixed:
        log(
            f"  restored {fixed} integrity entries npm 11.x dropped "
            "(shrinkwrap peer tree; from registry dist.integrity)"
        )

    shutil.copy(lockfile, target_dir / "package-lock.json")
    return target_dir / "package-lock.json"


def fix_missing_integrity(lockfile: Path) -> int:
    """Fill in `integrity` for lock entries npm recorded without it.

    npm 11.17 (node 24.19, repo pin) omits integrity for entries nested under
    a shrinkwrapped dependency's peer tree; fetchNpmDeps/prefetch-npm-deps
    panic on those ("non-git dependencies should have associated"). The
    entries have registry `resolved` URLs, so the sha512 SRI is recoverable
    from the registry packument. Non-registry entries are left untouched.
    """
    data = json.loads(lockfile.read_text())
    packages = data.get("packages", {})
    fixed = 0
    for key, entry in packages.items():
        if not isinstance(entry, dict) or "integrity" in entry:
            continue
        resolved = entry.get("resolved") or ""
        if not resolved.startswith("https://registry.npmjs.org/"):
            continue
        name = key.rsplit("node_modules/", 1)[-1]
        version = entry.get("version")
        if not version:
            continue
        doc = registry.fetch_doc(name)
        dist = doc.get("versions", {}).get(version, {}).get("dist", {})
        integrity = dist.get("integrity")
        if not integrity:
            raise UpdateError(f"{name}@{version}: registry has no dist.integrity to restore")
        entry["integrity"] = integrity
        fixed += 1
    if fixed:
        lockfile.write_text(json.dumps(data, indent=2) + "\n")
    return fixed


def prefetch_deps_hash(lockfile: Path) -> str:
    """npmDepsHash via prefetch-npm-deps (one-shot fetch; matches
    fetchNpmDeps' cache hash). Warnings on stderr are expected."""
    tool = _shutil_which("prefetch-npm-deps")
    proc = _run([tool, str(lockfile)], timeout=1800)
    match = HASH_RE.search(proc.stdout)
    if proc.returncode != 0 or match is None:
        raise UpdateError(
            f"prefetch-npm-deps failed (rc={proc.returncode}): "
            f"{(proc.stderr or proc.stdout).strip()[-2000:]}"
        )
    return match.group(0)


def parse_got_hash(output: str) -> str | None:
    """Extract the actual hash from a nix hash-mismatch failure."""
    match = GOT_HASH_RE.search(output)
    return match.group(1) if match else None


def _nix_build(pkg: Package, root: Path) -> subprocess.CompletedProcess[str]:
    nix_build = _shutil_which("nix-build")
    return _run(
        [nix_build, str(root), "-A", f"third_party.pi-extensions.{pkg.dir_name}"],
        timeout=3600,
    )


def fake_hash_loop(pkg: Package, root: Path) -> str:
    """Two-pass fallback: build against lib.fakeHash, take the `got:` hash
    from the failure, write it, rebuild. Needs nothing beyond nix."""
    rewrite_attr(pkg.default_nix, "npmDepsHash", FAKE_HASH)
    proc = _nix_build(pkg, root)
    got = parse_got_hash(proc.stdout + proc.stderr)
    if got is None:
        raise UpdateError(f"fake-hash build failed without a got: hash: {_tail(proc)}")
    rewrite_attr(pkg.default_nix, "npmDepsHash", got)
    verify = _nix_build(pkg, root)
    if verify.returncode != 0:
        raise UpdateError(f"rebuild with recovered hash failed: {_tail(verify)}")
    return got


def _tail(proc: subprocess.CompletedProcess[str]) -> str:
    return (proc.stdout + proc.stderr).strip()[-2000:]


def resolve_npm_deps_hash(
    pkg: Package,
    root: Path,
    lockfile: Path,
    do_build: bool,
    log: Callable[[str], None],
) -> str:
    """npmDepsHash: prefetch primary, verify-build reconciliation, fake-hash
    loop fallback (kept implemented per the design doc)."""
    try:
        candidate = prefetch_deps_hash(lockfile)
    except UpdateError as e:
        if not do_build:
            raise UpdateError(f"{e} (and --no-build forbids the fake-hash fallback)") from e
        log(f"  prefetch failed ({e}); falling back to fake-hash loop")
        return fake_hash_loop(pkg, root)

    if not do_build:
        return candidate

    rewrite_attr(pkg.default_nix, "npmDepsHash", candidate)
    proc = _nix_build(pkg, root)
    if proc.returncode == 0:
        return candidate

    got = parse_got_hash(proc.stdout + proc.stderr)
    if got is None:
        log(f"  verify build failed without hash mismatch: {_tail(proc)}")
        return fake_hash_loop(pkg, root)
    log(f"  prefetch hash disagreed with build; adopting got: {got}")
    rewrite_attr(pkg.default_nix, "npmDepsHash", got)
    verify = _nix_build(pkg, root)
    if verify.returncode != 0:
        raise UpdateError(f"rebuild with adopted hash failed: {_tail(verify)}")
    return got


def update_package(
    pkg: Package,
    root: Path,
    version: str,
    do_build: bool,
    log: Callable[[str], None],
) -> None:
    """Bump one package to `version`. Raises UpdateError on failure; the
    working tree is left dirty for inspection (git is the undo)."""
    log(f"== {pkg.dir_name} ({pkg.npm_name}) {pkg.pinned_version} -> {version}")
    base = packages_dir(root)

    with tempfile.TemporaryDirectory(prefix="piext-update-") as tmp:
        work_dir = Path(tmp)
        tarball = download_tarball(pkg.npm_name, version, work_dir)
        src_hash = hash_tarball(tarball)
        log(f"  srcHash: {src_hash}")
        lockfile = regenerate_lockfile(tarball, pkg.default_nix.parent, work_dir)

        write_versions(base, pkg.npm_name, version)
        rewrite_attr(pkg.default_nix, "srcHash", src_hash)
        fix_src_comment(pkg.default_nix)

        resolve_npm_deps_hash(pkg, root, lockfile, do_build, log)

    if do_build:
        log(f"  verify build: OK ({pkg.dir_name})")


# --- CLI -------------------------------------------------------------------


def _select_targets(packages: list[Package], names: list[str], select_all: bool) -> list[Package]:
    if select_all:
        return packages
    if not names:
        raise UpdateError("no packages given: pass names or --all")
    by_key = {p.dir_name: p for p in packages} | {p.npm_name: p for p in packages}
    targets = []
    for name in names:
        pkg = by_key.get(name)
        if pkg is None:
            known = ", ".join(sorted({p.npm_name for p in packages}))
            raise UpdateError(f"unknown package {name!r} (known: {known})")
        targets.append(pkg)
    return targets


def dirty_guard(root: Path) -> None:
    proc = _run(
        ["git", "-C", str(root), "status", "--porcelain", "--", str(discover.PI_EXTENSIONS_SUBDIR)]
    )
    if proc.stdout.strip():
        raise UpdateError(
            "third_party/pi-extensions is dirty; the tool needs a clean tree "
            "so its edits stay diffable/revertable (git is the undo)"
        )


def run(args: argparse.Namespace) -> int:
    root = discover.repo_root()
    try:
        dirty_guard(root)
        packages = discover.discover(root)
        targets = _select_targets(packages, args.names, args.all)
    except UpdateError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    failures = 0
    for pkg in targets:
        try:
            version = registry.resolve_version(pkg.npm_name, args.version)
            if version == pkg.pinned_version and args.version is None:
                print(f"== {pkg.dir_name}: already at latest {version}, skipping")
                continue
            update_package(
                pkg,
                root,
                version,
                do_build=not args.no_build,
                log=log,
            )
        except (UpdateError, registry.RegistryError) as e:
            failures += 1
            print(f"== {pkg.dir_name}: FAILED: {e}", file=sys.stderr)

    print()
    print("git diff summary:")
    proc = _run(
        ["git", "-C", str(root), "diff", "--stat", "--", str(discover.PI_EXTENSIONS_SUBDIR)]
    )
    print(proc.stdout.strip() or "(no changes)")
    return 1 if failures else 0
