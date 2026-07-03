"""Label clusters via a local instruction-tuned LLM (Phase 4).

Reads ``summary.json`` produced by Phase 3, sends each cluster's
centroid samples + metadata to a local model (default: Mistral-7B),
and writes a ``labels.json`` mapping ``cluster_id → label``.

Resumable: re-running skips clusters already present in the output.
"""

import argparse
import json
import re
import sys
import time
from pathlib import Path

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

from email_trainer.config import Config

# ---------------------------------------------------------------------------
# Prompt template
# ---------------------------------------------------------------------------

_SYSTEM_PROMPT = """\
You are labeling email clusters for a classification system. Each cluster \
contains emails on a similar topic. Your job is to suggest a short label \
(1-3 words) and note any emails that seem like they don't belong in the \
cluster.

Respond with exactly:

LABEL: <1-3 word label>
NOTES: <brief note about any misclassified emails, or "None">
"""


def _build_prompt(cluster: dict) -> str:
    """Build the user message for a single cluster."""
    lines: list[str] = []
    lines.append("Cluster samples (nearest to centroid):")
    lines.append("")

    for i, s in enumerate(cluster.get("samples", []), 1):
        subj = s.get("subject") or "(no subject)"
        snippet = (s.get("body_snippet") or "")[:200].replace("\n", " ")
        lines.append(f"{i}. Subject: {subj}")
        lines.append(f"   Snippet: {snippet}")
        lines.append("")

    # Add top domains if available
    domains = cluster.get("top_domains", [])
    if domains:
        domain_str = ", ".join(f"{d['domain']} ({d['count']}x)" for d in domains[:8])
        lines.append(f"Top sender domains: {domain_str}")
        lines.append("")

    # Add top subject tokens if available
    tokens = cluster.get("top_subject_tokens", [])
    if tokens:
        token_str = ", ".join(f"'{t['token']}' ({t['count']}x)" for t in tokens[:8])
        lines.append(f"Common subject words: {token_str}")
        lines.append("")

    lines.append(
        "Suggest a short label (1-3 words) that describes this category. "
        "Also note any emails that seem misclassified."
    )

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Response parsing
# ---------------------------------------------------------------------------

_LABEL_RE = re.compile(r"LABEL:\s*(.+?)(?:\n|$)", re.IGNORECASE)
_NOTES_RE = re.compile(r"NOTES:\s*(.+)", re.IGNORECASE | re.DOTALL)


def _parse_response(text: str) -> tuple[str, str | None]:
    """Extract label and optional notes from the model response.

    Looks for ``LABEL:`` and ``NOTES:`` markers.  Falls back to using
    the first non-empty line as the label when the markers are missing.
    """
    label_match = _LABEL_RE.search(text)
    notes_match = _NOTES_RE.search(text)

    label = label_match.group(1).strip() if label_match else None
    notes = notes_match.group(1).strip() if notes_match else None

    if not label:
        # Fallback: first non-empty line after stripping common cruft
        for line in text.strip().splitlines():
            line = line.strip().strip('"').strip("'")
            if line and not line.startswith(("[INST", "[/INST]", "<s>", "</s>")):
                label = line[:60]
                break
        if not label:
            label = "unlabeled"

    notes = notes[:500] if notes else None

    return label, notes


# ---------------------------------------------------------------------------
# Model loading
# ---------------------------------------------------------------------------


@torch.inference_mode()
def _load_model(model_path: str | Path) -> tuple:
    """Load a local huggingface-style model and tokenizer.

    Returns ``(model, tokenizer)`` with the model in FP16 on CUDA.
    Exits on failure.
    """
    path = Path(model_path).expanduser().resolve()
    if not path.exists():
        print(f"Error: model path not found: {path}", file=sys.stderr)
        sys.exit(1)

    print(f"Loading model from {path}\u2026", file=sys.stderr)
    t0 = time.time()

    tokenizer = AutoTokenizer.from_pretrained(path.as_posix())

    # Load directly on CUDA to avoid broken transformers .cuda()/.to() stubs
    with torch.device("cuda"):
        model = AutoModelForCausalLM.from_pretrained(
            path.as_posix(),
            torch_dtype=torch.float16,
            low_cpu_mem_usage=True,
        )
    model.eval()

    elapsed = time.time() - t0
    n_params = sum(p.numel() for p in model.parameters())
    print(
        f"  Loaded {n_params / 1e9:.1f}B param model in {elapsed:.1f}s",
        file=sys.stderr,
    )
    return model, tokenizer


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------


def run_label(args: argparse.Namespace) -> None:
    """Execute the ``label`` subcommand — Phase 4 of the pipeline.

    Reads ``summary.json`` from Phase 3, labels each cluster via a local
    LLM, and writes ``labels.json``.
    """
    kwargs = {}
    if args.storage_dir:
        kwargs["storage_dir"] = args.storage_dir
    config = Config(**kwargs)

    summary_path = config.clusters_dir_resolved / "summary.json"
    labels_path = config.clusters_dir_resolved / "labels.json"

    # ── Validate inputs ────────────────────────────────────
    if not summary_path.exists():
        print(
            f"Error: summary.json not found at {summary_path} — run `email-trainer cluster` first.",
            file=sys.stderr,
        )
        sys.exit(1)

    with open(summary_path) as f:
        summary = json.load(f)

    clusters = summary.get("clusters", [])
    if not clusters:
        print("Error: no clusters found in summary.json", file=sys.stderr)
        sys.exit(1)

    print(f"Loaded {len(clusters)} clusters from {summary_path}", file=sys.stderr)

    # ── Resumability: load existing labels ──────────────────
    existing_labels: dict = {}
    if labels_path.exists():
        with open(labels_path) as f:
            existing = json.load(f)
        existing_labels = existing.get("labels", {})
        print(
            f"  {len(existing_labels)} clusters already labeled ({labels_path})",
            file=sys.stderr,
        )

    # Determine which clusters still need labeling
    pending = [c for c in clusters if str(c["cluster_id"]) not in existing_labels]
    if args.limit is not None:
        pending = pending[: args.limit]

    if not pending:
        print("All clusters already labeled. Nothing to do.", file=sys.stderr)
        return

    print(f"  {len(pending)} cluster{'s' if len(pending) != 1 else ''} to label", file=sys.stderr)

    # ── Load model ──────────────────────────────────────────
    model, tokenizer = _load_model(args.model_path)

    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    # ── Label clusters ──────────────────────────────────────
    # Copy existing labels so we can merge
    labels = dict(existing_labels)

    gen_kwargs = {
        "max_new_tokens": args.max_new_tokens,
        "do_sample": args.temperature > 0,
        "temperature": args.temperature if args.temperature > 0 else None,
        "pad_token_id": tokenizer.pad_token_id,
        "eos_token_id": tokenizer.eos_token_id,
    }

    for i, cluster in enumerate(pending):
        cid = str(cluster["cluster_id"])
        size = cluster.get("size", "?")
        print(
            f"  [{i + 1}/{len(pending)}] Cluster {cid} ({size} emails)\u2026",
            file=sys.stderr,
        )

        prompt = _build_prompt(cluster)
        messages = [
            {"role": "system", "content": _SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ]
        input_ids = tokenizer.apply_chat_template(
            messages,
            return_tensors="pt",
            add_generation_prompt=True,
        ).to("cuda")

        with torch.inference_mode():
            output_ids = model.generate(input_ids, **gen_kwargs)

        # Only the newly generated tokens
        new_tokens = output_ids[0][input_ids.shape[1] :]
        response = tokenizer.decode(new_tokens, skip_special_tokens=True).strip()

        label, notes = _parse_response(response)
        labels[cid] = {
            "label": label,
            "notes": notes or None,
        }

        if args.verbose:
            print(f"    → {label}", file=sys.stderr)
            if notes:
                print(f"      notes: {notes[:120]}", file=sys.stderr)

    # ── Write output ────────────────────────────────────────
    metadata = {
        "model": str(Path(args.model_path).expanduser().resolve()),
        "model_load_args": {
            "torch_dtype": "float16",
        },
        "generation_args": {k: v for k, v in gen_kwargs.items() if v is not None},
        "n_clusters_total": len(clusters),
        "n_clusters_labeled": len(labels),
        "n_clusters_this_run": len(pending),
    }

    output = {
        "labels": labels,
        "metadata": metadata,
    }

    with open(labels_path, "w") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)

    print(f"\nLabels written to {labels_path}", file=sys.stderr)
    n_unlabeled = len(clusters) - len(labels)
    if n_unlabeled > 0:
        print(
            f"  {n_unlabeled} cluster{'s' if n_unlabeled != 1 else ''} "
            f"remain unlabeled (re-run to continue)",
            file=sys.stderr,
        )
    else:
        print("  All clusters labeled.", file=sys.stderr)
