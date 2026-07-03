"""Embed extracted email texts using sentence-transformers (Phase 2).

Reads ``texts.jsonl`` from the Phase 1 extraction output, encodes each
email's ``text`` field into a vector using a local sentence-transformers
model (default: bge-m3), and writes two NumPy arrays:

* ``embeddings/email_ids.npy`` — int64 array of shape (N,) containing
  the ``email_id`` for each embedded email.
* ``embeddings/embeddings.npy`` — float32 array of shape (N, 1024)
  containing the corresponding dense embeddings.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from sentence_transformers import SentenceTransformer

from email_trainer.config import Config


def run_embed(args: argparse.Namespace) -> None:
    """Execute the ``embed`` subcommand — Phase 2 of the pipeline.

    Model path, device, batch size, and a processing limit are all
    configurable via *args* (parsed by ``_add_embed_parser`` in *cli.py*).
    """
    kwargs = {}
    if args.storage_dir:
        kwargs["storage_dir"] = args.storage_dir
    config = Config(**kwargs)

    model_path = Path(args.model_path).expanduser().resolve()
    embeddings_dir = config.embeddings_dir_resolved
    texts_path = config.extracted_dir_resolved / "texts.jsonl"
    ids_path = embeddings_dir / "email_ids.npy"
    embs_path = embeddings_dir / "embeddings.npy"

    # ── Validate inputs ──
    if not model_path.exists():
        print(
            f"Error: model path not found: {model_path}",
            file=sys.stderr,
        )
        sys.exit(1)

    if not texts_path.exists():
        print(
            f"Error: extracted texts not found at {texts_path} — "
            "run `email-trainer extract` first.",
            file=sys.stderr,
        )
        sys.exit(1)

    # ── Device selection ──
    device = args.device or ("cuda" if _cuda_available() else "cpu")

    # ── Load model ──
    print(
        f"Loading model from {model_path} (device={device})…",
        file=sys.stderr,
    )
    model = SentenceTransformer(
        model_path.as_posix(),
        device=device,
    )
    print(
        f"  Model loaded.  max_seq_length={model.max_seq_length}  "
        f"output dimension={model.get_embedding_dimension()}",
        file=sys.stderr,
    )

    # ── Resumability: load already-embedded IDs ──
    already_embedded: set[int] = set()
    if ids_path.exists():
        existing_ids = np.load(ids_path)
        already_embedded = set(existing_ids.tolist())
        print(
            f"Resuming: {len(already_embedded)} emails already embedded ({ids_path})",
            file=sys.stderr,
        )

    # ── Stream texts, collecting batches to encode ──
    embeddings_dir.mkdir(parents=True, exist_ok=True)

    batch_size = args.batch_size
    limit = args.limit

    # Temporarily accumulate (id, text) for the current batch
    batch_ids: list[int] = []
    batch_texts: list[str] = []

    all_ids: list[int] = []
    all_embeddings: list[np.ndarray] = []

    count_in_current_run = 0

    def _encode_batch() -> None:
        """Encode ``batch_texts`` and append results, then clear the batch."""
        nonlocal batch_ids, batch_texts
        if not batch_ids:
            return
        embs = model.encode(
            batch_texts,
            batch_size=batch_size,
            convert_to_numpy=True,
            show_progress_bar=False,
        )
        # embs shape: (len(batch), 1024)
        all_embeddings.append(embs)
        all_ids.extend(batch_ids)
        batch_ids = []
        batch_texts = []

    print(f"Encoding emails…  (batch_size={batch_size})", file=sys.stderr)

    with open(texts_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            record = json.loads(line)
            email_id: int = record["email_id"]

            if email_id in already_embedded:
                continue

            # Limit check
            if limit is not None and count_in_current_run >= limit:
                break

            batch_ids.append(email_id)
            batch_texts.append(record["text"])
            count_in_current_run += 1

            # Flush the batch when it reaches the target size
            if len(batch_ids) >= batch_size:
                _encode_batch()
                if count_in_current_run % 200 == 0:
                    print(
                        f"  {count_in_current_run} processed…",
                        file=sys.stderr,
                    )

        # Flush any remaining texts
        _encode_batch()

    if count_in_current_run == 0:
        print("No new emails to embed.  Nothing to do.", file=sys.stderr)
        return

    # ── Concatenate into single arrays ──
    embeddings_array = np.vstack(all_embeddings).astype(np.float32)
    ids_array = np.array(all_ids, dtype=np.int64)

    # If resuming, prepend existing data
    if already_embedded:
        existing_ids_arr = np.load(ids_path)
        existing_embs_arr = np.load(embs_path)
        ids_array = np.concatenate([existing_ids_arr, ids_array])
        embeddings_array = np.concatenate([existing_embs_arr, embeddings_array])

    # ── Atomic write: temp file then rename ──
    tmp_ids = ids_path.with_suffix(".tmp.npy")
    tmp_embs = embs_path.with_suffix(".tmp.npy")

    np.save(tmp_ids, ids_array)
    np.save(tmp_embs, embeddings_array)

    tmp_ids.replace(ids_path)
    tmp_embs.replace(embs_path)

    print(
        f"\nDone.  Embedded {count_in_current_run} emails (total: {len(ids_array)}).",
        file=sys.stderr,
    )
    print(
        f"  email_ids: {ids_path}  shape={ids_array.shape}",
        file=sys.stderr,
    )
    print(
        f"  embeddings: {embs_path}  shape={embeddings_array.shape}",
        file=sys.stderr,
    )


def _cuda_available() -> bool:
    """Return True if PyTorch reports CUDA is available."""
    try:
        import torch

        return torch.cuda.is_available()
    except ImportError:
        return False
