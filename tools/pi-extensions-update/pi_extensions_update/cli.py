"""Command-line interface for pi-extensions-update."""

import argparse
import sys

from pi_extensions_update import __version__, add, check, status, update

DESCRIPTION = """\
Manage the nix-packaged pi extensions in third_party/pi-extensions.

Commands:
  status    Show pinned vs registry-latest vs ad-hoc-installed versions
  update    Bump one or more packages (registry latest, or --version)
  add       Add a new package from an npm name
  check     Exit nonzero if pins are stale (CI-able)

See docs/pi-extensions-update-tool.md for the full design.
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pi-extensions-update",
        description=DESCRIPTION,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--version", action="version", version=__version__)
    sub = parser.add_subparsers(dest="command", metavar="command")

    sub.add_parser("status", help="pinned vs latest vs installed versions")

    update_parser = sub.add_parser("update", help="bump packages")
    update_parser.add_argument(
        "names", nargs="*", help="dir names or npm names (empty + no --all: error)"
    )
    update_parser.add_argument("--all", action="store_true", help="target every package")
    update_parser.add_argument(
        "--version", metavar="V", help="pin this version instead of registry latest"
    )
    update_parser.add_argument(
        "--no-build", action="store_true", help="skip verify builds (hashes still computed)"
    )

    add_parser = sub.add_parser("add", help="add a new package from an npm name")
    add_parser.add_argument("npm_name", help="npm registry name (e.g. @scope/pkg)")
    add_parser.add_argument(
        "--version", metavar="V", help="pin this version instead of registry latest"
    )
    add_parser.add_argument(
        "--dir", metavar="NAME", help="directory name (default: npm name minus @scope/)"
    )
    add_parser.add_argument(
        "--no-build", action="store_true", help="skip verify builds (hashes still computed)"
    )

    check_parser = sub.add_parser("check", help="exit nonzero if stale (CI-able)")
    check_parser.add_argument(
        "--against",
        choices=("latest", "installed"),
        default="latest",
        help="compare pins to registry latest (default) or ad-hoc installs",
    )
    return parser


def main() -> None:
    args = build_parser().parse_args()
    if args.command is None:
        build_parser().print_help()
        return
    if args.command == "status":
        sys.exit(status.run())
    if args.command == "update":
        sys.exit(update.run(args))
    if args.command == "add":
        sys.exit(add.run(args))
    if args.command == "check":
        sys.exit(check.run(args))
    # argparse restricts --command to the registered subparsers, so every
    # path above covers dispatch; no fallback is reachable.
    raise AssertionError(f"unhandled subcommand: {args.command}")


if __name__ == "__main__":
    main()
