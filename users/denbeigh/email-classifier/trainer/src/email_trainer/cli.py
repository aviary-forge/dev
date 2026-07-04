"""CLI entry point for email-trainer.

Parses arguments and dispatches to the appropriate pipeline phase.
"""

import argparse
import concurrent.futures
import json
import os
import sys
import threading
from pathlib import Path
from typing import Any

from email_trainer.clean_text import clean_email_text
from email_trainer.cluster import run_hdbscan, run_kmeans, run_refine
from email_trainer.config import Config
from email_trainer.db import Database
from email_trainer.embed import run_embed
from email_trainer.label import run_label
from email_trainer.train import run_train


def _add_label_parser(subparsers: argparse._SubParsersAction) -> None:
    """Register the ``label`` subcommand."""
    p = subparsers.add_parser(
        "label",
        help="Label clusters using a local LLM (Phase 4)",
        description=(
            "Read cluster summaries from Phase 3, send each cluster's "
            "centroid samples + metadata to a local instruction-tuned LLM, "
            "and write a labels.json mapping cluster_id to textual label."
        ),
    )
    p.add_argument(
        "--model-path",
        required=True,
        help="Path to a local transformers-compatible model directory",
    )
    p.add_argument(
        "--max-new-tokens",
        type=int,
        default=64,
        help="Max tokens to generate per cluster (default: 64)",
    )
    p.add_argument(
        "--temperature",
        type=float,
        default=0.1,
        help="Sampling temperature (default: 0.1; 0 = greedy)",
    )
    p.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Max clusters to label (for testing)",
    )
    p.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Print each label as it's generated",
    )
    p.add_argument(
        "--run-name",
        default=None,
        help=("Subdirectory for output (e.g. qwen3-label). Default: labels/"),
    )
    p.add_argument(
        "--cluster-run",
        default=None,
        help=(
            "Cluster run subdirectory to read summary.json from "
            "(e.g. experiment-1). Default: clusters/"
        ),
    )
    p.add_argument(
        "--body-chars",
        type=int,
        default=500,
        help=(
            "Max body characters to include per sample (default: 500; "
            "stored limit is 500 — re-cluster with larger n_samples for more)"
        ),
    )
    p.add_argument(
        "--max-samples",
        type=int,
        default=None,
        help=(
            "Max samples per cluster to include in prompt (default: all, as set at cluster time)"
        ),
    )
    p.add_argument(
        "--max-prompt-tokens",
        type=int,
        default=None,
        help=(
            "Soft token budget for the input prompt per cluster "
            "(default: no limit; e.g. 24576 leaves room for 8K of generation)"
        ),
    )
    p.add_argument(
        "--system-prompt",
        default=None,
        help=(
            "Path to a custom system prompt file. Overrides the default "
            "prompt that expects 'LABEL:' and 'NOTES:' output. "
            "The file is read verbatim as the system message content."
        ),
    )


def _add_cluster_parser(subparsers: argparse._SubParsersAction) -> None:
    """Register the ``cluster`` parent subcommand with nested algorithm parsers."""
    p = subparsers.add_parser(
        "cluster",
        help="Cluster embeddings or refine existing clusters (Phase 3)",
        description=(
            "Load embeddings from Phase 2 and cluster them, or refine "
            "existing cluster labels with noise recovery. "
            "Run ``cluster hdbscan``, ``cluster kmeans``, or ``cluster refine`` "
            "for algorithm-specific flags."
        ),
    )
    # Common args shared by all cluster algorithm subcommands
    p.add_argument(
        "--n-samples",
        type=int,
        default=20,
        help="Samples per cluster for review / labeling (default: 20)",
    )
    p.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Max emails to process (for testing)",
    )
    p.add_argument(
        "--embed-run",
        default=None,
        help=("Embed run-name to read from (e.g. gte-small). Default: embeddings/"),
    )
    p.add_argument(
        "--run-name",
        default=None,
        help="Subdirectory for output (e.g. clusters/experiment-1). Default: clusters/",
    )

    cluster_subparsers = p.add_subparsers(
        dest="cluster_subcommand",
        title="Algorithms",
        description="Select the clustering algorithm to use.",
        required=True,
    )

    # ── hdbscan ──
    h = cluster_subparsers.add_parser(
        "hdbscan",
        help="Density-based clustering (HDBSCAN)",
        description=(
            "Cluster embeddings using HDBSCAN. Finds natural density-based "
            "clusters without requiring a fixed K. Points that don't fit any "
            "cluster are labelled as noise (-1)."
        ),
    )
    h.add_argument(
        "--min-cluster-size",
        type=int,
        default=100,
        help="Minimum cluster size (default: 100)",
    )
    h.add_argument(
        "--min-samples",
        type=int,
        default=25,
        help=("min_samples (default: 25; lower than --min-cluster-size to encourage merging)"),
    )
    h.add_argument(
        "--cluster-selection-epsilon",
        type=float,
        default=0.0,
        help=(
            "Cluster selection epsilon (default: 0.0). Values >0 merge "
            "close clusters — start at 0.3 and increment carefully. "
            "WARNING: sklearn 1.9.0 has a known crash in epsilon_search "
            "with certain data distributions at epsilon > 0."
        ),
    )
    h.add_argument(
        "--cluster-selection-method",
        choices=("eom", "leaf"),
        default="eom",
        help="Cluster selection method (default: eom)",
    )
    h.add_argument(
        "--noise-sample",
        type=int,
        default=0,
        help=(
            "Sample N random noise points and write them to noise_samples.json "
            "(default: 0 = disabled)"
        ),
    )
    h.add_argument(
        "--epsilon-step",
        type=float,
        default=None,
        help=(
            "Epsilon sweep step size. Enables sweep mode: runs HDBSCAN at each "
            "epsilon value from --cluster-selection-epsilon to --epsilon-max, "
            "reports metrics for each, and skips writing outputs. "
            "Crashes at individual values don't abort the sweep. "
            "(default: disabled; e.g. 0.05 sweeps 0.0, 0.05, 0.1, \u2026, 0.5)"
        ),
    )
    h.add_argument(
        "--epsilon-max",
        type=float,
        default=0.5,
        help="Maximum epsilon for sweep mode (default: 0.5)",
    )
    h.add_argument(
        "--min-cluster-size-ratio",
        type=float,
        default=None,
        help=(
            "Fraction of total emails for min_cluster_size "
            "(e.g. 0.005 \u2192 120 for 24K emails). "
            "Overrides --min-cluster-size when set."
        ),
    )
    h.add_argument(
        "--post-merge-similar",
        type=float,
        default=None,
        help=(
            "Merge clusters whose centroid cosine similarity is at or above "
            "this threshold. Reads pairs from the just-computed "
            "similar_clusters analysis, finds connected components, and "
            "reassigns labels. A workaround for sklearn 1.9.0's "
            "epsilon_search crash at epsilon > 0. "
            "(default: disabled; try 0.75)"
        ),
    )

    # ── kmeans ──
    k = cluster_subparsers.add_parser(
        "kmeans",
        help="Fixed-K clustering (K-means)",
        description=(
            "Cluster embeddings using K-means with k-means++ initialization. "
            "Requires --n-clusters. All points are assigned to a cluster "
            "(no noise label). Best for enforcing even category spread."
        ),
    )
    k.add_argument(
        "--n-clusters",
        type=int,
        required=True,
        help="Number of clusters (required)",
    )

    # ── refine ──
    r = cluster_subparsers.add_parser(
        "refine",
        help="Refine cluster labels by recovering noise points (Phase 3b)",
        description=(
            "Read an existing cluster run and apply a two-stage noise "
            "refinement: (1) recluster noise with relaxed HDBSCAN to catch "
            "micro-clusters, (2) assign remaining noise to the nearest "
            "cluster centroid if within a similarity threshold. "
            "Writes a new set of cluster labels."
        ),
    )
    r.add_argument(
        "--cluster-run",
        default=None,
        help=(
            "Source cluster run to refine (e.g. experiment-1). "
            "Default: clusters/ directory."
        ),
    )
    r.add_argument(
        "--recluster-min-cluster-size",
        type=int,
        default=5,
        help=(
            "Minimum cluster size for noise reclustering (default: 5). "
            "Lower than the primary pass since we're looking for micro-clusters."
        ),
    )
    r.add_argument(
        "--recluster-min-samples",
        type=int,
        default=2,
        help=(
            "min_samples for noise reclustering (default: 2). "
            "Low value encourages even small dense pockets to form clusters."
        ),
    )
    r.add_argument(
        "--assign-threshold",
        type=float,
        default=0.6,
        help=(
            "Cosine similarity threshold for nearest-centroid assignment "
            "(default: 0.6, range 0-1). Higher = stricter, only very similar "
            "noise points get assigned."
        ),
    )
    r.add_argument(
        "--noise-sample",
        type=int,
        default=0,
        help=(
            "Sample N random remaining noise points and write them to "
            "noise_samples.json (default: 0 = disabled)"
        ),
    )


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
    p.add_argument(
        "--workers",
        type=int,
        default=None,
        help=(
            "Number of parallel worker threads for .eml extraction "
            "(default: min(32, cpu_count + 4)). "
            "On a high-core-count machine with fast storage, "
            "start at 16 and work up."
        ),
    )


def _add_embed_parser(subparsers: argparse._SubParsersAction) -> None:
    """Register the ``embed`` subcommand."""
    p = subparsers.add_parser(
        "embed",
        help="Embed extracted texts using sentence-transformers (Phase 2)",
        description=(
            "Load a local sentence-transformers model (default: bge-m3), "
            "read extracted texts from Phase 1, encode each one into a "
            "dense vector, and save NumPy arrays to the storage directory."
        ),
    )
    p.add_argument(
        "--model-path",
        default="~/small-models/bge-m3/",
        help="Path to local sentence-transformers model directory (default: ~/small-models/bge-m3/)",
    )
    p.add_argument(
        "--device",
        choices=("cuda", "cpu"),
        default=None,
        help="Torch device (default: cuda if available else cpu)",
    )
    p.add_argument(
        "--batch-size",
        type=int,
        default=16,
        help="Batch size for encoding (default: 16)",
    )
    p.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Max emails to process (for testing)",
    )
    p.add_argument(
        "--max-seq-length",
        type=int,
        default=None,
        help=(
            "Override the model's default max_seq_length for embedding. "
            "Useful for Qwen3-Embedding (defaults to 32K) — lower to 8192 "
            "for faster throughput with minimal quality loss. "
            "(default: model default)"
        ),
    )
    p.add_argument(
        "--run-name",
        default=None,
        help=("Subdirectory for output (e.g. embeddings/gte-small). Default: embeddings/"),
    )


def _add_train_parser(subparsers: argparse._SubParsersAction) -> None:
    """Register the ``train`` subcommand."""
    p = subparsers.add_parser(
        "train",
        help="Train a SetFit classifier on cluster-labeled data (Phase 5)",
        description=(
            "Read the cluster pipeline output (texts.jsonl, cluster_labels.npy, "
            "labels.json), merge them into a labeled dataset, train a SetFit "
            "classifier on top of a sentence-transformer model (default: "
            "nomic-embed-text-v1.5), evaluate on a held-out test set, and save "
            "both the full model and an ONNX export."
        ),
    )
    p.add_argument(
        "--model-path",
        default="~/small-models/nomic-embed-text-v1.5/",
        help=(
            "Path to local sentence-transformer model directory "
            "(default: ~/small-models/nomic-embed-text-v1.5/)"
        ),
    )
    p.add_argument(
        "--run-name",
        default=None,
        help="Name for this training run (default: auto-generated timestamp)",
    )
    p.add_argument(
        "--cluster-run",
        default=None,
        help=(
            "Cluster run subdirectory to read labels from (e.g. experiment-1). Default: clusters/"
        ),
    )
    p.add_argument(
        "--test-split",
        type=float,
        default=0.2,
        help="Fraction of data for test set (default: 0.2)",
    )
    p.add_argument(
        "--num-epochs",
        type=int,
        default=1,
        help="Number of contrastive training epochs (default: 1)",
    )
    p.add_argument(
        "--batch-size",
        type=int,
        default=16,
        help="Batch size for training (default: 16)",
    )
    p.add_argument(
        "--num-iterations",
        type=int,
        default=20,
        help="Number of contrastive pairs per example (default: 20)",
    )
    p.add_argument(
        "--learning-rate",
        type=float,
        default=2e-5,
        help="Learning rate (default: 2e-5)",
    )
    p.add_argument(
        "--max-seq-length",
        type=int,
        default=2048,
        help="Max tokens to truncate to (default: 2048)",
    )
    p.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed (default: 42)",
    )
    p.add_argument(
        "--noise-label",
        default="other",
        help="Label for noise / unlabeled emails (default: other)",
    )
    p.add_argument(
        "--limit-labels",
        type=int,
        default=None,
        help="Only use the N most frequent labels (for testing)",
    )
    p.add_argument(
        "--flash-attention",
        action="store_true",
        help=(
            "Enable flash_attention_2 for the transformer backbone. "
            "Loads the model in fp16 with left padding. "
            "Requires a compatible GPU and transformers>=4.40."
        ),
    )
    p.add_argument(
        "--skip-onnx",
        action="store_true",
        help="Skip ONNX export (only save SetFit format)",
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
                except json.JSONDecodeError, KeyError:
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

    # Filter to pending (unprocessed) emails
    pending = [rec for rec in emails if rec.email_id not in processed_ids]
    n_pending = len(pending)
    n_skipped = len(emails) - n_pending

    print(
        f"Extracting clean text…  (output: {output_path})",
        file=sys.stderr,
    )
    print(
        f"  {len(emails)} emails in DB, {n_skipped} already extracted, {n_pending} to process",
        file=sys.stderr,
    )

    if not pending:
        print("No new emails to extract.  Nothing to do.", file=sys.stderr)
        db.close()
        return

    n_workers = args.workers or min(32, (os.cpu_count() or 1) + 4)
    print(f"  Using {n_workers} worker threads", file=sys.stderr)

    extracted_count = 0
    error_count = 0
    write_lock = threading.Lock()

    with (
        open(output_path, "a") as out_f,
        concurrent.futures.ThreadPoolExecutor(max_workers=n_workers) as executor,
    ):
        futures = {
            executor.submit(_extract_one, eml_dir, rec, args.use_preview): rec for rec in pending
        }

        done = 0
        for future in concurrent.futures.as_completed(futures):
            done += 1
            rec = futures[future]

            try:
                record = future.result()
            except Exception as e:
                print(
                    f"  Unhandled error for email_id={rec.email_id}: {e}",
                    file=sys.stderr,
                )
                error_count += 1
                continue

            if record is None:
                error_count += 1
                continue

            with write_lock:
                out_f.write(json.dumps(record, ensure_ascii=False) + "\n")
            extracted_count += 1

            if done % 100 == 0 or done == n_pending:
                print(
                    f"  [{done}/{n_pending}] extracted={extracted_count} errors={error_count}",
                    file=sys.stderr,
                )

    print(
        f"\nDone.  extracted={extracted_count}  skipped={n_skipped}  errors={error_count}",
        file=sys.stderr,
    )
    db.close()


def _extract_one(
    eml_dir: Path,
    rec: Any,
    use_preview: bool,
) -> dict | None:
    """Extract clean text from a single email record.

    Returns a JSONL-ready dict on success, or ``None`` on error.
    Prints errors to stderr but does not abort the batch.
    """
    eml_path = eml_dir / rec.eml_path_rel
    try:
        text = clean_email_text(
            eml_path,
            subject=rec.subject,
            from_addr=rec.from_addr,
            body_preview=rec.body_preview,
            use_preview=use_preview,
        )
    except Exception as e:
        print(
            f"  Error processing email_id={rec.email_id}: {e}",
            file=sys.stderr,
        )
        return None

    return {
        "email_id": rec.email_id,
        "folder": rec.folder_name,
        "from_addr": rec.from_addr,
        "subject": rec.subject,
        "text": text,
        "char_count": len(text),
    }


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="email-trainer",
        description=(
            "Embedding + clustering pipeline for email classification. "
            "Processes .eml files produced by email-loader through multiple "
            "stages: extract \u2192 embed \u2192 cluster \u2192 label."
        ),
    )

    parser.add_argument(
        "--storage-dir",
        default="",
        help="Override storage root directory for all phases",
    )

    subparsers = parser.add_subparsers(
        dest="subcommand",
        title="Pipeline phases",
        description="Run `email-trainer <phase> --help` for phase-specific options.",
        required=True,
    )

    _add_extract_parser(subparsers)

    _add_embed_parser(subparsers)

    _add_cluster_parser(subparsers)

    _add_label_parser(subparsers)

    _add_train_parser(subparsers)

    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = _parse_args(argv)

    if args.subcommand == "extract":
        _handle_extract(args)
    elif args.subcommand == "embed":
        run_embed(args)
    elif args.subcommand == "cluster":
        if args.cluster_subcommand == "hdbscan":
            run_hdbscan(args)
        elif args.cluster_subcommand == "kmeans":
            run_kmeans(args)
        elif args.cluster_subcommand == "refine":
            run_refine(args)
        else:
            print(
                f"Unknown cluster algorithm: {args.cluster_subcommand}",
                file=sys.stderr,
            )
            sys.exit(1)
    elif args.subcommand == "label":
        run_label(args)
    elif args.subcommand == "train":
        run_train(args)
    else:
        print(
            f"Unknown subcommand: {args.subcommand}",
            file=sys.stderr,
        )
        sys.exit(1)
