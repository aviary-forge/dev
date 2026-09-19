#!/usr/bin/env python3
"""Build and activate a system config from the monorepo.

The monorepo root and target are cached in $MONOREPO_TARGET_FILE (default
/etc/monorepo-target) as `root=`/`target=` lines, so after the first run —
or any run with --target — no arguments are needed. Builds <target>.activate
via nix-build (streaming build output) and runs the activation script via
`sudo -H`. Works for nixos, darwin, and home-manager configs.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

DEFAULT_TARGET_FILE = "/etc/monorepo-target"

ROOT_KEY = "root"
TARGET_KEY = "target"

USAGE = f"""\
usage: mono-switch [--target | -t <target>] [--build-only | -b]
       mono-switch --help

Builds <target>.activate from the monorepo and activates it. The target and
monorepo root are cached in $MONOREPO_TARGET_FILE (default
{DEFAULT_TARGET_FILE}), so after the first run (or any run with --target)
no arguments are needed. The `.activate` suffix is appended automatically,
but is also accepted if you include it.

resolution order:
  target: --target flag, then the cached target file
  root:   $MONOREPO_ROOT, then git (cwd), then the cached root, then
          ~/dev/dev, ~/dev

options:
  --target, -t <target>  target to build and activate; also cached for
                         subsequent runs
  --build-only, -b       build and print the store path without activating
  --help, -h             show this help

Activation requires root; the tool re-execs the activation script via
`sudo -H` automatically.
"""


def is_monorepo(candidate: Path) -> bool:
    """Check whether `candidate` looks like the dev monorepo root."""
    return (candidate / "nix" / "readTree" / "default.nix").is_file() and (
        candidate / "default.nix"
    ).is_file()


def parse_target_file(target_file: Path) -> dict[str, str]:
    """Parse the cache file.

    `root=`/`target=` key/value lines; a bare legacy line (no `=`) is
    treated as just the target, for files predating the root cache.
    """
    try:
        lines = target_file.read_text().splitlines()
    except OSError as exc:
        sys.exit(f"could not read {target_file}: {exc}")

    entries: dict[str, str] = {}
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if sep and key.strip() in (ROOT_KEY, TARGET_KEY):
            entries[key.strip()] = value.strip()
        else:
            entries.setdefault(TARGET_KEY, line)
    return entries


def resolve_root(cached_root: str | None) -> tuple[Path, str]:
    """Find the monorepo checkout; returns (path, source)."""
    if env := os.environ.get("MONOREPO_ROOT"):
        cand = Path(env)
        if not cand.is_dir() or not is_monorepo(cand):
            sys.exit(f"MONOREPO_ROOT={env} is not a monorepo checkout")
        return cand, "$MONOREPO_ROOT"

    def _homedir(suffix: str) -> Path:
        return Path(os.path.expanduser(suffix))

    # Try git (i.e. the cwd's checkout), then the cached root, then the
    # well-known checkout paths.
    git_cand: Path | None = None
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            git_cand = Path(result.stdout.strip())
    # Git may fail (no git, not a repo, timeout); fall through to the
    # cached root and well-known checkout paths instead.
    except (FileNotFoundError, subprocess.TimeoutExpired):
        git_cand = None

    candidates: list[tuple[Path, str]] = []
    if git_cand is not None:
        candidates.append((git_cand, "git (cwd)"))
    if cached_root:
        candidates.append((Path(cached_root), "cache"))
    candidates.append((_homedir("~/dev/dev"), "~/dev/dev"))
    candidates.append((_homedir("~/dev"), "~/dev"))

    for cand, source in candidates:
        if cand.is_dir() and is_monorepo(cand):
            return cand, source

    sys.exit(
        "could not locate monorepo\n"
        "tried: git rev-parse --show-toplevel, the cached root, ~/dev/dev, ~/dev\n"
        "set MONOREPO_ROOT to the checkout path"
    )


def parse_args(argv: list[str]) -> tuple[str | None, bool]:
    """Return (target_override, build_only) from argv."""
    target: str | None = None
    build_only = False
    i = 0
    while i < len(argv):
        arg = argv[i]
        i += 1
        if arg in ("--help", "-h"):
            print(USAGE, end="")
            sys.exit(0)
        elif arg in ("--build-only", "-b"):
            build_only = True
        elif arg in ("--target", "-t"):
            if i >= len(argv):
                sys.exit(f"mono-switch: {arg} requires a value\n\n{USAGE}")
            target = argv[i]
            i += 1
        elif arg.startswith("--target="):
            target = arg.removeprefix("--target=")
        else:
            sys.exit(f"mono-switch: unrecognized argument '{arg}'\n\n{USAGE}")
    return target, build_only


def _sudo_tee(target_file: Path, contents: str) -> str | None:
    """Write via `sudo tee`; return an error message, or None on success."""
    # sudo prompts on the tty, so capturing stderr is safe while stdin
    # carries the contents through tee.
    proc = subprocess.run(
        ["sudo", "tee", str(target_file)],
        input=contents,
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        return proc.stderr.strip() or "sudo declined"
    return None


def write_target_file(target_file: Path, monorepo: Path, target: str) -> None:
    """Persist the root and target, elevating with sudo only if needed."""
    contents = f"root={monorepo}\ntarget={target}\n"
    try:
        target_file.write_text(contents)
    except OSError:
        # Likely /etc or similar: retry through sudo.
        err = _sudo_tee(target_file, contents)
        if err is not None:
            sys.exit(f"could not write {target_file}: {err}")
    print(f"[mono-switch] cached root and target in {target_file}")


def create_target_file(target_file: Path, monorepo: Path) -> str:
    """Interactively create the target file and return the target."""
    if not sys.stdin.isatty():
        # Refuse to "prompt" from a pipe; scripts should pass the target
        # explicitly instead.
        sys.exit(
            f"no target cached in {target_file} (and stdin is not a tty)\n\n"
            "pass a target on the command line:\n"
            "  mono-switch -t systems.configs.aviary\n\n"
            "or create the target file:\n"
            f"  printf 'root=$HOME/dev/dev\\ntarget=systems.configs.aviary\\n' "
            f"| sudo tee {target_file}\n\n"
            "targets are at readTree paths under systems/ and users/*/systems/"
        )

    print(
        f"no target cached in {target_file}\n\n"
        "targets are readTree paths under systems/ and users/*/systems/, e.g.\n"
        "  systems.configs.aviary\n"
    )
    target = ""
    while not target:
        try:
            target = input(f"target to cache in {target_file} (blank to abort): ").strip()
        except (EOFError, KeyboardInterrupt):
            sys.exit("\naborted")

    write_target_file(target_file, monorepo, target)
    return target


def resolve_target(
    flag: str | None, target_file: Path, cached: dict[str, str], monorepo: Path
) -> str:
    if flag is not None:
        return flag

    if target := cached.get(TARGET_KEY):
        print(f"[mono-switch] target {target} (from {target_file})")
        return target

    return create_target_file(target_file, monorepo)


def build_activate(monorepo: Path, target: str) -> str:
    """Build the target's activate attribute and return the store path.

    stderr is inherited so nix's eval/build progress streams live instead
    of being swallowed until completion; stdout is captured for the path.

    Accepts the target with or without its `.activate` suffix.
    """
    attr = target if target.endswith(".activate") else f"{target}.activate"
    print(f"[mono-switch] building {attr}...")
    proc = subprocess.Popen(
        ["nix-build", "--no-out-link", str(monorepo), "-A", attr],
        stdout=subprocess.PIPE,
        text=True,
    )
    stdout, _ = proc.communicate()
    if proc.returncode != 0:
        sys.exit(f"nix-build failed for {attr} (exit {proc.returncode})")

    store_path = stdout.strip()
    if not store_path:
        sys.exit(f"nix-build produced no store path for {attr}")
    return store_path


def main() -> None:
    target_flag, build_only = parse_args(sys.argv[1:])
    target_file = Path(os.environ.get("MONOREPO_TARGET_FILE", DEFAULT_TARGET_FILE))

    cached = parse_target_file(target_file) if target_file.is_file() else {}
    monorepo, root_source = resolve_root(cached.get(ROOT_KEY))
    print(f"[mono-switch] root {monorepo} (from {root_source})")

    target = resolve_target(target_flag, target_file, cached, monorepo)
    store_path = build_activate(monorepo, target)

    # Persist the last explicitly provided root + target for next time. The
    # interactive bootstrap already wrote the cache; cache-served runs leave
    # it untouched.
    if target_flag is not None:
        write_target_file(target_file, monorepo, target)

    if build_only:
        print(store_path)
        return

    activate_bin = Path(store_path) / "bin" / "activate"
    if not activate_bin.is_file():
        sys.exit(f"activation binary not found: {activate_bin}")

    # Activate as root via `sudo -H`: -H sets HOME to root's so Nix doesn't
    # warn about the invoking user's home, and the activation wrappers
    # (nix-darwin/NixOS) need EUID 0 anyway. No env passthrough is needed —
    # the wrapper is self-contained.
    if os.geteuid() != 0:
        if shutil.which("sudo") is None:
            sys.exit("activation requires root, but sudo is not available")
        print("[mono-switch] activating (via sudo -H)...")
        os.execvp("sudo", ["sudo", "-H", str(activate_bin)])

    print("[mono-switch] activating...")
    os.execv(str(activate_bin), [str(activate_bin)])


if __name__ == "__main__":
    main()
