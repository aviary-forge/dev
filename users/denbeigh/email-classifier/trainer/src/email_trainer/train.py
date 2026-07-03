"""Train a SetFit classifier on cluster-labeled email data (Phase 5).

Reads the cluster pipeline output (``texts.jsonl``, ``email_ids.npy``,
``cluster_labels.npy``, ``labels.json``), merges them into a labeled
dataset, trains a SetFit model on top of a base sentence-transformer
(default: ``nomic-embed-text-v1.5``), evaluates on a held-out test set,
and saves both the full model (sentence-transformers format) and an ONNX
export for deployment.
"""

import argparse
import json
import sys
import time
from collections import Counter
from pathlib import Path

import numpy as np
from datasets import Dataset
from setfit import SetFitModel, TrainingArguments
from setfit import Trainer as SetFitTrainer
from sklearn.metrics import (
    accuracy_score,
    confusion_matrix,
    f1_score,
    precision_recall_fscore_support,
)
from sklearn.model_selection import train_test_split

from email_trainer.config import Config

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _now_tag() -> str:
    """Return a compact timestamp like ``v1-2026-07-02`` for run naming."""
    return "v1-" + time.strftime("%Y-%m-%d")


def _load_training_data(
    config: Config,
    noise_label: str = "other",
    limit_labels: int | None = None,
    cluster_dir: Path | None = None,
) -> tuple[list[str], list[str], dict[str, int], dict[str, int]]:
    """Merge cluster pipeline artifacts into a training-ready dataset.

    *cluster_dir* overrides the clusters directory (for ``--cluster-run``).

    Returns:
        A 4-tuple ``(texts, label_names, label_map, label_counts)`` where:
        - *texts* — list of email body strings
        - *label_names* — list of human-readable label strings (parallel to *texts*)
        - *label_map* — ``{label_name: int_id}`` (sorted alphabetically)
        - *label_counts* — ``{label_name: count}`` for the training subset
    """
    cd = cluster_dir or config.clusters_dir_resolved
    paths = (
        config.extracted_dir_resolved / "texts.jsonl",
        config.embeddings_dir_resolved / "email_ids.npy",
        cd / "cluster_labels.npy",
        cd / "labels.json",
    )

    texts_path, ids_path, clabels_path, labels_json_path = paths

    for p, label in zip(
        paths,
        ("texts.jsonl", "email_ids.npy", "cluster_labels.npy", "labels.json"),
        strict=True,
    ):
        if not p.exists():
            print(
                f"Error: {label} not found at {p} — run `email-trainer cluster` and `email-trainer label` first.",
                file=sys.stderr,
            )
            sys.exit(1)

    # ── Load cluster → label mapping ──
    with open(labels_json_path) as f:
        labels_data = json.load(f)
    cluster_to_label: dict[str, str] = labels_data.get("labels", {})

    # ── Load email IDs and cluster assignments ──
    email_ids = np.load(ids_path)  # shape (N,)
    cluster_ids = np.load(clabels_path)  # shape (N,)

    # ── Load email texts ──
    texts_by_id: dict[int, str] = {}
    with open(texts_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            texts_by_id[rec["email_id"]] = rec.get("text", "")

    # ── Merge ──
    texts: list[str] = []
    label_names: list[str] = []

    for eid, cid in zip(email_ids.tolist(), cluster_ids.tolist(), strict=True):
        text = texts_by_id.get(eid)
        if text is None or not text.strip():
            continue  # skip emails with no extracted text

        # Determine the label
        if cid == -1:
            lbl = noise_label
        else:
            lbl = cluster_to_label.get(str(cid), noise_label)
            if lbl is None or lbl.strip().lower() in ("", "unlabeled", "none"):
                lbl = noise_label

        texts.append(text)
        label_names.append(lbl)

    # ── Build label map (sorted alphabetically) ──
    counts = Counter(label_names)
    unique_labels = sorted(counts.keys())

    # Optionally limit to the N most frequent labels (for testing)
    if limit_labels is not None and limit_labels < len(unique_labels):
        top_n = [lbl for lbl, _ in counts.most_common(limit_labels)]
        # Filter data
        filtered = [(t, lbl) for t, lbl in zip(texts, label_names, strict=True) if lbl in top_n]
        if not filtered:
            print(
                f"Error: --limit-labels={limit_labels} produced an empty dataset.",
                file=sys.stderr,
            )
            sys.exit(1)
        texts, label_names = zip(*filtered, strict=True) if filtered else ([], [])
        texts = list(texts)
        label_names = list(label_names)
        unique_labels = sorted(set(label_names))

    label_map = {lbl: idx for idx, lbl in enumerate(unique_labels)}
    label_counts = {lbl: counts[lbl] for lbl in unique_labels}

    print(
        f"Loaded {len(texts)} labeled emails across {len(unique_labels)} labels.",
        file=sys.stderr,
    )
    for lbl in unique_labels:
        print(f"  {lbl}: {counts[lbl]}", file=sys.stderr)

    return texts, label_names, label_map, label_counts


def _stratified_split(
    texts: list[str],
    y: list[int],
    test_size: float,
    seed: int,
) -> tuple[list[str], list[str], list[int], list[int]]:
    """Stratified train/test split on label-encoded *y*.

    Returns ``(train_texts, test_texts, train_labels, test_labels)``.
    """
    train_texts, test_texts, train_y, test_y = train_test_split(
        texts,
        y,
        test_size=test_size,
        random_state=seed,
        stratify=y,
    )
    return train_texts, test_texts, train_y, test_y


def _train_setfit(
    model_path: str | Path,
    train_texts: list[str],
    train_labels: list[int],
    eval_texts: list[str],
    eval_labels: list[int],
    num_epochs: int,
    batch_size: int,
    num_iterations: int,
    learning_rate: float,
    max_seq_length: int,
    seed: int,
) -> tuple[SetFitModel, dict]:
    """Create, train, and evaluate a SetFit model.

    Returns ``(trained_model, metrics)`` where *metrics* is a dict of
    evaluation results on the eval set.
    """
    model_path = str(Path(model_path).expanduser().resolve())

    print(f"Loading base model from {model_path}…", file=sys.stderr)
    t0 = time.time()

    model = SetFitModel.from_pretrained(
        model_path,
        use_differentiable_head=True,  # PyTorch head — cleaner ONNX export
    )

    # Set max sequence length on the underlying sentence transformer
    model.model_body.max_seq_length = max_seq_length

    elapsed = time.time() - t0
    print(f"  Loaded in {elapsed:.1f}s", file=sys.stderr)
    print(
        f"  Output dim: {model.model_body.get_sentence_embedding_dimension()}",
        file=sys.stderr,
    )

    # ── Build HuggingFace Datasets ──
    train_dataset = Dataset.from_dict({"text": train_texts, "label": train_labels})
    eval_dataset = Dataset.from_dict({"text": eval_texts, "label": eval_labels})

    # ── Training arguments ──
    args = TrainingArguments(
        batch_size=batch_size,
        num_epochs=num_epochs,
        num_iterations=num_iterations,  # contrastive pairs per example
        learning_rate=learning_rate,
        seed=seed,
    )

    # ── Trainer ──
    trainer = SetFitTrainer(
        model=model,
        args=args,
        train_dataset=train_dataset,
        eval_dataset=eval_dataset,
    )

    # ── Train ──
    print(
        f"Training: {len(train_texts)} train, {len(eval_texts)} eval, "
        f"{num_epochs} epoch(s), batch={batch_size}",
        file=sys.stderr,
    )
    t0 = time.time()
    trainer.train()
    elapsed = time.time() - t0
    print(f"  Training completed in {elapsed:.1f}s", file=sys.stderr)

    # ── Evaluate ──
    print("Evaluating…", file=sys.stderr)
    preds = model(eval_texts)
    if hasattr(preds, "numpy"):
        preds = preds.numpy()
    preds = preds.tolist() if hasattr(preds, "tolist") else list(preds)

    acc = accuracy_score(eval_labels, preds)
    f1_macro = f1_score(eval_labels, preds, average="macro", zero_division=0)
    f1_weighted = f1_score(eval_labels, preds, average="weighted", zero_division=0)
    per_class = precision_recall_fscore_support(eval_labels, preds, zero_division=0)
    cm = confusion_matrix(eval_labels, preds)

    metrics = {
        "accuracy": round(float(acc), 4),
        "f1_macro": round(float(f1_macro), 4),
        "f1_weighted": round(float(f1_weighted), 4),
        "per_class": [],
        "confusion_matrix": cm.tolist(),
        "n_train": len(train_texts),
        "n_test": len(eval_texts),
    }

    unique_eval_labels = sorted(set(eval_labels))
    for idx in unique_eval_labels:
        metrics["per_class"].append(
            {
                "label_id": int(idx),
                "precision": round(float(per_class[0][idx]), 4),
                "recall": round(float(per_class[1][idx]), 4),
                "f1": round(float(per_class[2][idx]), 4),
                "support": int(per_class[3][idx]),
            }
        )

    print(f"  Accuracy:  {metrics['accuracy']:.4f}", file=sys.stderr)
    print(f"  F1 (macro):   {metrics['f1_macro']:.4f}", file=sys.stderr)
    print(f"  F1 (weighted): {metrics['f1_weighted']:.4f}", file=sys.stderr)

    return model, metrics


def _export_onnx(
    model: SetFitModel,
    output_dir: Path,
) -> None:
    """Export the trained SetFit model to ONNX.

    Uses SetFit's built-in ``export_onnx()`` function, which handles both
    PyTorch-differentiable and sklearn heads.
    """
    onnx_dir = output_dir / "onnx"
    onnx_dir.mkdir(parents=True, exist_ok=True)
    onnx_path = onnx_dir / "model.onnx"

    print(f"Exporting to ONNX: {onnx_path}…", file=sys.stderr)
    t0 = time.time()

    from setfit.exporters.onnx import export_onnx

    export_onnx(
        model_body=model.model_body,
        model_head=model.model_head,
        opset=17,
        output_path=str(onnx_path),
    )

    elapsed = time.time() - t0
    model_size_mb = onnx_path.stat().st_size / (1024 * 1024)
    print(f"  ONNX exported in {elapsed:.1f}s ({model_size_mb:.0f} MB)", file=sys.stderr)

    # ── Copy tokenizer files alongside the ONNX model ──
    tokenizer_files = [
        "tokenizer.json",
        "special_tokens_map.json",
        "tokenizer_config.json",
        "vocab.txt",
    ]
    # Find the tokenizer in the sentence transformer's first module
    body = model.model_body
    if hasattr(body, "_first_module") and body._first_module is not None:
        tok_dir = Path(body._first_module.tokenizer_files_folder)
    elif hasattr(body, "tokenizer") and hasattr(body.tokenizer, "name_or_path"):
        # Some ST models store tokenizer in the model directory
        tok_dir = Path(body.tokenizer.name_or_path)
    else:
        # Fall back to the sentence transformer's model path
        tok_dir = Path(body._modules["0"].tokenizer_files_folder)

    for fname in tokenizer_files:
        src = tok_dir / fname
        if src.exists():
            dst = onnx_dir / fname
            dst.write_bytes(src.read_bytes())
            print(f"    Copied {fname}", file=sys.stderr)


def _save_model(
    model: SetFitModel,
    output_dir: Path,
    label_map: dict[str, int],
    label_counts: dict[str, int],
    metrics: dict,
    training_args: dict,
) -> None:
    """Save all training artifacts to *output_dir*."""
    output_dir.mkdir(parents=True, exist_ok=True)

    # ── Full SetFit model (sentence-transformers format) ──
    model_dir = output_dir / "model"
    print(f"Saving SetFit model to {model_dir}…", file=sys.stderr)
    model.save_pretrained(str(model_dir))
    print("  Saved.", file=sys.stderr)

    # ── Metadata ──
    with open(output_dir / "label_map.json", "w") as f:
        json.dump(label_map, f, indent=2, ensure_ascii=False)
    with open(output_dir / "label_counts.json", "w") as f:
        json.dump(label_counts, f, indent=2, ensure_ascii=False)
    with open(output_dir / "metrics.json", "w") as f:
        json.dump(metrics, f, indent=2, ensure_ascii=False)
    with open(output_dir / "training_args.json", "w") as f:
        json.dump(training_args, f, indent=2, ensure_ascii=False)

    print(f"\nAll artifacts saved to {output_dir}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def run_train(args: argparse.Namespace) -> None:
    """Execute the ``train`` subcommand — train SetFit classifier from cluster pipeline output."""
    kwargs = {}
    if args.storage_dir:
        kwargs["storage_dir"] = args.storage_dir
    config = Config(**kwargs)

    model_path = Path(args.model_path).expanduser().resolve()
    if not model_path.exists():
        print(
            f"Error: base model path not found: {model_path}",
            file=sys.stderr,
        )
        sys.exit(1)

    # ── Run name ──
    run_name = args.run_name or _now_tag()
    output_dir = config.models_dir_resolved / run_name
    if output_dir.exists():
        print(
            f"Error: output directory already exists: {output_dir}\n"
            f"  Delete or rename it, or use a different --run-name.",
            file=sys.stderr,
        )
        sys.exit(1)

    # ── Resolve cluster run directory ──
    cluster_dir: Path | None = None
    if args.cluster_run:
        cluster_dir = config.clusters_dir_resolved / args.cluster_run
        print(f"Using cluster run: {cluster_dir}", file=sys.stderr)

    # ── Load and prepare data ──
    print("Loading training data…", file=sys.stderr)
    texts, label_names, label_map, label_counts = _load_training_data(
        config,
        noise_label=args.noise_label,
        limit_labels=args.limit_labels,
        cluster_dir=cluster_dir,
    )
    y = [label_map[lbl] for lbl in label_names]

    # ── Stratified split ──
    train_texts, test_texts, train_labels, test_labels = _stratified_split(
        texts,
        y,
        test_size=args.test_split,
        seed=args.seed,
    )
    print(
        f"Split: {len(train_texts)} train, {len(test_texts)} test",
        file=sys.stderr,
    )

    # ── Train ──
    model, metrics = _train_setfit(
        model_path=model_path,
        train_texts=train_texts,
        train_labels=train_labels,
        eval_texts=test_texts,
        eval_labels=test_labels,
        num_epochs=args.num_epochs,
        batch_size=args.batch_size,
        num_iterations=args.num_iterations,
        learning_rate=args.learning_rate,
        max_seq_length=args.max_seq_length,
        seed=args.seed,
    )

    # ── Save model ──
    training_args = {
        "run_name": run_name,
        "model_path": str(model_path),
        "test_split": args.test_split,
        "num_epochs": args.num_epochs,
        "batch_size": args.batch_size,
        "num_iterations": args.num_iterations,
        "learning_rate": args.learning_rate,
        "max_seq_length": args.max_seq_length,
        "seed": args.seed,
        "noise_label": args.noise_label,
        "limit_labels": args.limit_labels,
    }

    _save_model(
        model,
        output_dir,
        label_map,
        label_counts,
        metrics,
        training_args,
    )

    # ── ONNX export ──
    if not args.skip_onnx:
        _export_onnx(
            model,
            output_dir,
        )

    print("\nDone.", file=sys.stderr)
