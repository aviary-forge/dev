"""CLI entry point for email-trainer.

Parses arguments and dispatches to the appropriate pipeline phase.
"""

import argparse
import json
import sys
from pathlib import Path

from email_trainer.clean_text import clean_email_text
from email_trainer.config import Config
from email_trainer.db import Database


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


def _load_processed_ids(output_path: Path) -> set[int]:
    """Return the set of ``email_id`` values already in the JSONL output.

    Used for resumability: skip emails that were already extracted in a
    previous run.
    """
    if not output_path.exists():
        return set()
    ids: set[int] = set()
    with open(output_path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    record = json.loads(line)
                    ids.add(record["email_id"])
                except (json.JSONDecodeError, KeyError):
                    continue
    return ids


def _handle_extract(args: argparse.Namespace) -> None:
    """Execute the ``extract`` subcommand — Phase 1 of the pipeline."""
    config = Config(
        db_path=args.db_path,
        eml_dir=args.eml_dir,
    )

    db_path = config.db_path_resolved
    eml_dir = config.eml_dir_resolved
    output_dir = config.extracted_dir_resolved
    output_path = Path(args.output) if args.output else output_dir / "texts.jsonl"

    # ── Validate DB exists ──
    if not db_path.exists():
        print(f"Error: index.db not found at {db_path}", file=sys.stderr)
        sys.exit(1)

    # ── Connect to DB ──
    db = Database(db_path)

    try:
        emails = db.list_emails(limit=args.limit)
    except Exception as e:
        print(f"Error querying database: {e}", file=sys.stderr)
        db.close()
        sys.exit(1)

    if not emails:
        print("No emails found in database.", file=sys.stderr)
        db.close()
        return

    # ── Dry-run: just report ──
    if args.dry_run:
        print(f"Would process {len(emails)} emails:", file=sys.stderr)
        for i, rec in enumerate(emails):
            print(
                f"  {i + 1}. [{rec.folder_name}] "
                f"ID={rec.email_id} "
                f"subject={rec.subject or '(no subject)'} "
                f"from={rec.from_addr or '(unknown)'}",
                file=sys.stderr,
            )
            if args.limit and i + 1 >= args.limit:
                break
        db.close()
        return

    # ── Real extraction ──
    output_dir.mkdir(parents=True, exist_ok=True)

    # Load already-processed IDs for resumability
    processed_ids = _load_processed_ids(output_path)
    skipped_count = 0
    extracted_count = 0
    error_count = 0

    print(
        f"Extracting clean text…  (output: {output_path})",
        file=sys.stderr,
    )
    print(
        f"  {len(emails)} emails in DB, {len(processed_ids)} already extracted",
        file=sys.stderr,
    )

    with open(output_path, "a") as out_f:
        for i, rec in enumerate(emails):
            # Progress indicator
            if (i + 1) % 100 == 0 or i == 0:
                print(
                    f"  [{i + 1}/{len(emails)}] "
                    f"extracted={extracted_count} "
                    f"skipped={skipped_count} "
                    f"errors={error_count}",
                    file=sys.stderr,
                )

            # Resumability: skip already-processed
            if rec.email_id in processed_ids:
                skipped_count += 1
                continue

            eml_path = eml_dir / rec.eml_path_rel
            subject = rec.subject
            from_addr = rec.from_addr

            try:
                text = clean_email_text(
                    eml_path,
                    subject=subject,
                    from_addr=from_addr,
                    body_preview=rec.body_preview,
                    use_preview=args.use_preview,
                )
            except Exception as e:
                print(
                    f"  Error processing email_id={rec.email_id}: {e}",
                    file=sys.stderr,
                )
                error_count += 1
                continue

            # Write JSONL record
            record = {
                "email_id": rec.email_id,
                "folder": rec.folder_name,
                "from_addr": from_addr,
                "subject": subject,
                "text": text,
                "char_count": len(text),
            }
            out_f.write(json.dumps(record, ensure_ascii=False) + "\n")
            extracted_count += 1

    print(
        f"\nDone.  extracted={extracted_count}  skipped={skipped_count}  errors={error_count}",
        file=sys.stderr,
    )
    db.close()


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="email-trainer",
        description=(
            "Embedding + clustering pipeline for email classification. "
            "Processes .eml files produced by email-loader through multiple "
            "stages: extract \u2192 embed \u2192 cluster \u2192 label."
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
