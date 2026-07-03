"""CLI entry point for email-trainer.

Parses arguments and dispatches to the appropriate pipeline phase.
"""

import argparse
import sys


def _add_extract_parser(subparsers: argparse._SubParsersAction) -> None:
    """Register the ``extract`` subcommand."""
    p = subparsers.add_parser(
        "extract",
        help="Extract clean text from .eml files (Phase 1)",
        description=(
            "Walk MIME parts in each .eml file, extract clean text, "
            "and write a JSONL file for downstream embedding."
        ),
    )
    p.add_argument(
        "--db-path",
        default="",
        help="Override path to the loader's index.db",
    )
    p.add_argument(
        "--eml-dir",
        default="",
        help="Override root directory of .eml files",
    )
    p.add_argument(
        "--output",
        default="",
        help="Output JSONL path (default: <storage>/extracted/texts.jsonl)",
    )
    p.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Max emails to process (for testing)",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="List emails that would be processed, don't write output",
    )
    p.add_argument(
        "--use-preview",
        action="store_true",
        help="Use body_preview from DB instead of full MIME parsing",
    )


def _handle_extract(args: argparse.Namespace) -> None:
    """Execute ``extract`` subcommand (stub — not yet implemented)."""
    print(
        "extract subcommand: not yet implemented — Phase 1 coming soon.",
        file=sys.stderr,
    )
    print(f"  db-path…… {args.db_path or '(default)'}", file=sys.stderr)
    print(f"  eml-dir…… {args.eml_dir or '(default)'}", file=sys.stderr)
    print(f"  output…… {args.output or '(default)'}", file=sys.stderr)
    print(f"  limit…… {args.limit}", file=sys.stderr)
    print(f"  dry-run… {args.dry_run}", file=sys.stderr)
    print(f"  use-preview {args.use_preview}", file=sys.stderr)


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="email-trainer",
        description=(
            "Embedding + clustering pipeline for email classification. "
            "Processes .eml files produced by email-loader through multiple "
            "stages: extract → embed → cluster → label."
        ),
    )

    subparsers = parser.add_subparsers(
        dest="subcommand",
        title="Pipeline phases",
        description="Run `email-trainer <phase> --help` for phase-specific options.",
        required=True,
    )

    _add_extract_parser(subparsers)

    # Future subcommands will be registered here:
    # _add_embed_parser(subparsers)
    # _add_cluster_parser(subparsers)
    # _add_label_parser(subparsers)

    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = _parse_args(argv)

    if args.subcommand == "extract":
        _handle_extract(args)
    else:
        print(
            f"Unknown subcommand: {args.subcommand}",
            file=sys.stderr,
        )
        sys.exit(1)
