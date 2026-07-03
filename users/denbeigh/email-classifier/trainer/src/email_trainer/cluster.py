"""Cluster embeddings using HDBSCAN (Phase 3).

Reads ``email_ids.npy`` and ``embeddings.npy`` from the Phase 2 output,
clusters the vectors using HDBSCAN (with k-means as a configurable fallback),
and writes::

    clusters/
    ├── cluster_labels.npy    # int64, shape (N,), aligned with email_ids.npy
    │                         # -1 = noise (HDBSCAN only)
    ├── summary.json          # per-cluster structured data for Phase 4
    └── review_dump.txt       # human-readable dump for Phase 3 validation
"""

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

import numpy as np
from sklearn.cluster import HDBSCAN, KMeans
from sklearn.metrics import silhouette_samples

from email_trainer.config import Config

# ---------------------------------------------------------------------------
# Stopwords for subject-token extraction
# ---------------------------------------------------------------------------
_SUBJECT_STOPWORDS = frozenset(
    {
        "a",
        "an",
        "the",
        "and",
        "or",
        "but",
        "in",
        "on",
        "at",
        "to",
        "for",
        "of",
        "with",
        "by",
        "from",
        "is",
        "are",
        "was",
        "were",
        "be",
        "been",
        "being",
        "have",
        "has",
        "had",
        "do",
        "does",
        "did",
        "will",
        "would",
        "could",
        "should",
        "may",
        "might",
        "shall",
        "can",
        "need",
        "dare",
        "ought",
        "used",
        "re",
        "fw",
        "fwd",
        "reply",
        "regarding",
        "about",
        "this",
        "that",
        "these",
        "those",
        "it",
        "its",
        "it's",
        "not",
        "no",
        "nor",
        "so",
        "if",
        "then",
        "than",
        "too",
        "very",
        "just",
        "also",
        "more",
        "some",
        "any",
        "each",
        "every",
        "all",
        "both",
        "few",
        "most",
        "other",
        "into",
        "over",
        "after",
        "before",
        "between",
        "under",
        "above",
        "below",
        "up",
        "down",
        "out",
        "off",
        "again",
        "further",
        "once",
        "here",
        "there",
        "when",
        "where",
        "why",
        "how",
        "what",
        "which",
        "who",
        "whom",
        "my",
        "your",
        "his",
        "her",
        "our",
        "their",
        "u",
        "ur",
        "n't",
        "'s",
        "'t",
        "'re",
        "'ve",
        "'ll",
        "'m",
        "'d",
        "doesn",
        "don",
        "didn",
        "won",
        "wouldn",
        "couldn",
        "shouldn",
        "isn",
        "aren",
        "wasn",
        "weren",
        "hasn",
        "havn",
        "hadn",
    }
)

# Compiled regex for email domain extraction.
_DOMAIN_RE = re.compile(r"@([\w.-]+)")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _extract_domain(from_addr: str | None) -> str | None:
    """Extract the domain part of an email address.

    Handles both ``user@domain`` and ``Name <user@domain>`` formats.
    Returns ``None`` when the address can't be parsed.
    """
    if not from_addr:
        return None
    match = _DOMAIN_RE.search(from_addr)
    return match.group(1).lower() if match else None


def _tokenize_subject(subject: str | None) -> list[str]:
    """Return cleaned, lowercased tokens from a subject line.

    Strips non-alpha characters and filters common stopwords / very
    short tokens.
    """
    if not subject:
        return []
    tokens = re.findall(r"[a-z]+", subject.lower())
    return [t for t in tokens if t not in _SUBJECT_STOPWORDS and len(t) > 1]


def _load_email_map(texts_path: Path) -> dict[int, dict]:
    """Load ``texts.jsonl`` into a ``{email_id: record}`` dict.

    Raises ``FileNotFoundError`` if the path doesn't exist.
    """
    email_map: dict[int, dict] = {}
    with open(texts_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            email_map[rec["email_id"]] = rec
    return email_map


# ---------------------------------------------------------------------------
# Silhouette
# ---------------------------------------------------------------------------


def _silhouette_stats(
    embeddings: np.ndarray,
    labels: np.ndarray,
) -> tuple[float | None, float | None, float | None]:
    """Compute silhouette metrics on non-noise points only.

    Returns ``(mean, min, max)``.  All three are ``None`` when there
    are fewer than 2 clusters or fewer than 2 non-noise points.
    """
    mask = labels != -1
    n_clustered = int(mask.sum())
    n_clusters = len(set(labels[mask]))

    if n_clusters < 2 or n_clustered < 2:
        return None, None, None

    scores = silhouette_samples(embeddings[mask], labels[mask])
    return float(scores.mean()), float(scores.min()), float(scores.max())


# ---------------------------------------------------------------------------
# Per-cluster analysis
# ---------------------------------------------------------------------------


def _build_cluster_summaries(
    labels: np.ndarray,
    embeddings: np.ndarray,
    email_ids: np.ndarray,
    email_map: dict[int, dict],
    n_samples: int = 20,
) -> dict:
    """Build structured per-cluster summaries.

    For each non-noise cluster:

    * **Size** — member count and percentage of total.
    * **Samples** — the *n_samples* emails whose embeddings are nearest
      to the cluster centroid (mean vector of member embeddings),
      including ``subject``, the first 500 chars of body text, and
      the Euclidean distance from the centroid.
    * **Top domains** — the 10 most frequent sender domains.
    * **Top subject tokens** — the 10 most frequent non-stopword
      tokens found in subject lines.
    """
    unique_labels = sorted(set(labels) - {-1})
    clusters: list[dict] = []
    n_total = len(labels)

    for cl in unique_labels:
        mask = labels == cl
        cl_embs = embeddings[mask]
        cl_ids = email_ids[mask]
        cl_size = int(mask.sum())

        # Centroid
        centroid = cl_embs.mean(axis=0)

        # Euclidean distances to centroid
        diffs = cl_embs - centroid
        dists = np.sqrt((diffs * diffs).sum(axis=1))
        nearest_idx = np.argsort(dists)[:n_samples]

        # Collect domain + subject tokens for ALL members
        domain_counter: Counter = Counter()
        subject_counter: Counter = Counter()

        for eid in cl_ids.tolist():
            rec = email_map.get(eid)
            if rec is None:
                continue
            domain = _extract_domain(rec.get("from_addr"))
            if domain:
                domain_counter[domain] += 1
            tokens = _tokenize_subject(rec.get("subject"))
            subject_counter.update(tokens)

        # Build samples list
        samples: list[dict] = []
        for idx in nearest_idx:
            eid = int(cl_ids[idx])
            rec = email_map.get(eid, {})
            body = rec.get("text") or ""
            samples.append(
                {
                    "email_id": eid,
                    "subject": rec.get("subject"),
                    "body_snippet": body[:500],
                    "distance": round(float(dists[idx]), 4),
                }
            )

        clusters.append(
            {
                "cluster_id": int(cl),
                "size": cl_size,
                "percentage": round(cl_size / n_total * 100, 1),
                "top_domains": [
                    {"domain": d, "count": c} for d, c in domain_counter.most_common(10)
                ],
                "top_subject_tokens": [
                    {"token": t, "count": c} for t, c in subject_counter.most_common(10)
                ],
                "samples": samples,
            }
        )

    return {"clusters": clusters}


# ---------------------------------------------------------------------------
# Review dump (human-readable)
# ---------------------------------------------------------------------------


def _write_review_dump(summary: dict, path: Path) -> None:
    """Write a plain-text summary for manual cluster validation."""
    lines: list[str] = []
    lines.append("=" * 72)
    lines.append("CLUSTER REVIEW DUMP")
    meta = summary.get("metadata", {})
    lines.append(f"  Total emails: {meta.get('n_total', '?')}")
    lines.append(f"  Clusters: {len(summary['clusters'])}")
    if meta.get("silhouette_mean") is not None:
        lines.append(
            f"  Silhouette: mean={meta['silhouette_mean']:.3f}  "
            f"min={meta['silhouette_min']:.3f}  "
            f"max={meta['silhouette_max']:.3f}"
        )
    lines.append("=" * 72)
    lines.append("")

    for cl in summary["clusters"]:
        lines.append(f"{'─' * 72}")
        lines.append(f"Cluster {cl['cluster_id']}  ({cl['size']} emails, {cl['percentage']}%)")
        lines.append(f"{'─' * 72}")
        lines.append("")

        if cl["top_domains"]:
            domains = ", ".join(f"{d['domain']} ({d['count']})" for d in cl["top_domains"][:5])
            lines.append(f"  Top domains:  {domains}")
            lines.append("")

        if cl["top_subject_tokens"]:
            tokens = ", ".join(
                f"'{t['token']}' ({t['count']})" for t in cl["top_subject_tokens"][:5]
            )
            lines.append(f"  Subject tokens:  {tokens}")
            lines.append("")

        lines.append("  Samples (nearest centroid):")
        for s in cl["samples"]:
            subj = s["subject"] or "(no subject)"
            # Truncate the snippet for display
            snippet = s["body_snippet"][:120].replace("\n", " ")
            lines.append(f"    [{s['email_id']}] {subj}")
            lines.append(f"      {snippet}…")
        lines.append("")

    path.write_text("\n".join(lines), encoding="utf-8")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def run_cluster(args: argparse.Namespace) -> None:
    """Execute the ``cluster`` subcommand — Phase 3 of the pipeline.

    Reads the embeddings produced by Phase 2, clusters them via HDBSCAN
    (or k-means), and writes three output files.
    """
    kwargs = {}
    if args.storage_dir:
        kwargs["storage_dir"] = args.storage_dir
    config = Config(**kwargs)

    embeddings_dir = config.embeddings_dir_resolved
    clusters_dir = config.clusters_dir_resolved
    texts_path = config.extracted_dir_resolved / "texts.jsonl"
    ids_path = embeddings_dir / "email_ids.npy"
    embs_path = embeddings_dir / "embeddings.npy"

    # ── Validate inputs ─────────────────────────────────────
    for p, label in (
        (ids_path, "email_ids.npy"),
        (embs_path, "embeddings.npy"),
        (texts_path, "texts.jsonl"),
    ):
        if not p.exists():
            print(
                f"Error: {label} not found at {p} — run `email-trainer embed` first.",
                file=sys.stderr,
            )
            sys.exit(1)

    # ── Load embeddings ─────────────────────────────────────
    print("Loading embeddings\u2026", file=sys.stderr)
    email_ids = np.load(ids_path)
    embeddings = np.load(embs_path)
    n_total = len(email_ids)
    print(
        f"  Loaded {n_total} embeddings, shape {embeddings.shape}",
        file=sys.stderr,
    )

    limit = args.limit
    if limit is not None and limit < n_total:
        print(f"  Limiting to first {limit} embeddings", file=sys.stderr)
        email_ids = email_ids[:limit]
        embeddings = embeddings[:limit]
        n_total = limit

    # ── Load email texts for sample enrichment ──────────────
    print("Loading email texts\u2026", file=sys.stderr)
    email_map = _load_email_map(texts_path)
    print(f"  Loaded {len(email_map)} email records", file=sys.stderr)

    # ── Run clustering ──────────────────────────────────────
    algorithm = args.algorithm
    print(
        f"Clustering with {algorithm} (min_cluster_size={args.min_cluster_size})\u2026",
        file=sys.stderr,
    )

    if algorithm == "hdbscan":
        clusterer = HDBSCAN(
            min_cluster_size=args.min_cluster_size,
            min_samples=args.min_samples,
            cluster_selection_epsilon=args.cluster_selection_epsilon,
            cluster_selection_method=args.cluster_selection_method,
            metric="euclidean",
        )
    else:
        # k-means
        if args.n_clusters is None:
            print(
                "Error: --n-clusters is required when --algorithm=kmeans.",
                file=sys.stderr,
            )
            sys.exit(1)
        clusterer = KMeans(
            n_clusters=args.n_clusters,
            init="k-means++",
            n_init="auto",
            random_state=42,
        )

    labels = clusterer.fit_predict(embeddings)

    n_clusters = len(set(labels) - {-1})
    n_noise = int((labels == -1).sum())
    print(
        f"  Found {n_clusters} cluster{'s' if n_clusters != 1 else ''}, "
        f"{n_noise} noise points "
        f"({n_noise / n_total * 100:.1f}%)",
        file=sys.stderr,
    )

    # ── Silhouette (non-noise only) ─────────────────────────
    sil_mean, sil_min, sil_max = _silhouette_stats(embeddings, labels)
    if sil_mean is not None:
        print(
            f"  Silhouette: mean={sil_mean:.3f}  min={sil_min:.3f}  max={sil_max:.3f}",
            file=sys.stderr,
        )
    else:
        print("  Silhouette: N/A (< 2 clusters or all noise)", file=sys.stderr)

    # ── Build cluster summaries ─────────────────────────────
    print("Building cluster summaries\u2026", file=sys.stderr)
    summary = _build_cluster_summaries(
        labels,
        embeddings,
        email_ids,
        email_map,
        n_samples=args.n_samples,
    )

    summary["metadata"] = {
        "algorithm": algorithm,
        "min_cluster_size": args.min_cluster_size,
        "min_samples": args.min_samples,
        "cluster_selection_epsilon": args.cluster_selection_epsilon,
        "cluster_selection_method": args.cluster_selection_method,
        "n_clusters": n_clusters,
        "n_noise": n_noise,
        "n_total": n_total,
        "silhouette_mean": sil_mean,
        "silhouette_min": sil_min,
        "silhouette_max": sil_max,
    }

    # ── Write outputs ───────────────────────────────────────
    clusters_dir.mkdir(parents=True, exist_ok=True)
    labels_path = clusters_dir / "cluster_labels.npy"
    summary_path = clusters_dir / "summary.json"
    review_path = clusters_dir / "review_dump.txt"

    np.save(labels_path, labels)
    print(f"  Labels:     {labels_path}  shape={labels.shape}", file=sys.stderr)

    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)
    print(f"  Summary:    {summary_path}", file=sys.stderr)

    _write_review_dump(summary, review_path)
    print(f"  Review:     {review_path}", file=sys.stderr)

    print("\nDone.", file=sys.stderr)
