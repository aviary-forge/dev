# Email Classification Pipeline

## Overview

Five-phase pipeline: batch label a multi-year email backlog with a local LLM,
review and correct those labels, train a small classifier on the resulting
dataset, deploy it, and continuously improve it as your mail patterns drift
and you catch mistakes.

---

## Phase 1: Batch Classification

**Goal:** Apply initial labels to every email in the backlog using a local LLM.

**Model:** 7B-8B parameter instruct model at Q4_K_M quantization.
Phi-4-mini, Llama 3.1 8B, or Mistral 7B — whatever you already have as a .gguf.

**Key technique:** GBNF grammar constraints force the model to output exactly
one label token. No parsing, no preamble, guaranteed valid.

```
root ::= "work" | "personal" | "newsletter" | "finance" | "receipt" |
         "travel" | "health" | "legal" | "shipping" | "social" | "ignore"
```

Start with a working taxonomy and expect to evolve it during Phase 2.

**Architecture:**

```
llama-server --model phi-4-mini-Q4_K_M.gguf --port 8080 --n-gpu-layers 99
```

```
[IMAP] ──fetch──▶ [Python script] ──POST /v1/completions──▶ [llama-server]
                      │                                           │
                      ▼                                           ▼
                  [SQLite]          ◀──────── label ──────────  GBNF grammar
               (message_id, label, timestamp)
```

**Design decisions:**

- **llama.cpp server, not in-process bindings.** Model stays loaded across the
  entire batch run. Script crash at email 38,000 doesn't cost a model reload.
- **SQLite for progress tracking.** `(message_id, label, classified_at)`.
  On restart, `SELECT message_id FROM classifications` to skip already-done
  emails. Also stores the raw classification for Phase 2 review.
- **Truncate body aggressively.** Subject + first ~1000 characters is enough
  signal for almost all emails. Skip attachments, strip quoted replies.
  This keeps context windows small and throughput high.
- **Concurrent IMAP + inference.** Use `asyncio` + `aiohttp` to overlap IMAP
  fetches with inference calls. Not critical but keeps the model from idling
  while the next email downloads.
- **Temperature 0.** Deterministic output. You're classifying, not workshopping.

**Estimated throughput:**

| Model size | Hardware       | Per email | 50K emails |
|-----------|----------------|-----------|------------|
| 7B Q4     | CPU (8 threads) | ~1s       | ~14 hours  |
| 7B Q4     | GPU offload     | ~200ms    | ~3 hours   |
| 3B Q4     | CPU (8 threads) | ~400ms    | ~5.5 hours |

The server + SQLite approach makes it fine to let this run over a weekend.

**Output:** A SQLite database mapping `message_id → label` for every email in
the backlog, plus a raw log of model responses for debugging.

### Pre-filtering: skip what can't be meaningfully classified

Not every email in a multi-year IMAP dump is worth running through the LLM.
Filter aggressively before inference — it saves time and keeps garbage labels
out of your training data.

**Skip by folder.** Don't fetch from `[Gmail]/Trash`, `[Gmail]/Spam`,
`Junk`, `Deleted Items`. These are already judged useless by you or your
provider's filter. If you delete spam on sight, there's nothing to learn from
it and no label to apply. If you *do* want to classify some spam (e.g. to
train a personal spam detector later), pull from Spam but give it a separate
`spam` label and exclude it from the classifier training set.

**Skip by content.** Drop emails before they hit the LLM if:

- **Body is empty** (subject-only, or body is just a tracking pixel). These
  are often automated notifications where the subject already tells you
  everything. Flag them as `auto: <subject-derived label>` or `skip:empty`.
- **Body is <100 characters after stripping signatures/quotes.** There's not
  enough text for the model to make a meaningful decision. Record as
  `skip:too-short`.
- **Non-English content.** If your taxonomy is English-centric and your model
  is English-trained, non-English emails get nonsense labels. Use a simple
  language-detection pass (`langdetect` or `fasttext` language model) and
  either skip them or route to a separate `non-english` bucket.
- **Pure attachments with no body text.** "See attached" with a PDF isn't
  classifiable from text alone. `skip:attachment-only`.
- **Bounce notifications, delivery failures, auto-replies.** These are
  infrastructure noise. Regex the subject for `Undeliverable`, `Out of
  Office`, `Auto-reply`. Label as `system` or skip entirely.

**Record skips explicitly, not silently.** Write a row to the DB with
`skip:<reason>` in the label column and `classified_at = NULL`. This lets you
audit later: "did I skip 15% of my mail because of an overly aggressive
filter?" If you drop them silently, you'll never know.

These filters carry forward into Phase 4 — the deployed classifier should
apply the same pre-filtering before inference so you're not burning CPU on
empty bodies or bounce notifications.

### Envelope feature extraction: signal from headers and metadata

Some labels can't be decided from body text alone, but the envelope carries
strong priors. These shouldn't short-circuit the model — they should be
encoded as input features the model learns to weigh alongside the text.
Decide later, during development, on the exact encoding scheme. Two
approaches worth considering:

- **Text prepending.** Encode features as structured tokens in the model
  input: `[FEATURES: plus_tag=amazon | steganography=yes | list_unsubscribe=yes]\n\nSubject: ...`.
  Hacky but works with any text-only model, including SetFit. The sentence
  transformer learns to associate feature tokens with label distributions
  without needing to understand their semantics.
- **Multi-input model.** If you graduate from SetFit to something more
  flexible (e.g. a small transformer with a feature concatenation head),
  pass features as a separate binary/categorical vector. Cleaner but more
  work for a v1.

The features themselves are deterministic to extract — the open question is
how best to feed them in. Hash this out during the Phase 3 build.

**Plus-address routing (RFC 5233 subaddressing).** If your mail provider
supports `user+tag@domain`, every address you give out encodes its origin.
Parse the `To:`/`Delivered-To:` header for `+<tag>`:

```python
import re

def extract_plus_tag(envelope_recipient: str) -> str | None:
    m = re.search(r"\+([^@]+)@", envelope_recipient)
    return m.group(1).lower() if m else None
```

If you haven't been using plus-addresses historically, this won't help your
backlog. But start now and every future email carries a free origin signal.
A `github` tag is a strong prior toward `work` or `dev-notification` —
but the model gets to decide, in combination with the body text, whether
it's a PR notification or a marketing email GitHub sold your address for.

**Unicode steganography in recipient name.** Scrapers and spammers often
hide tracking fingerprints in your displayed name using invisible Unicode
characters — zero-width spaces, joiners, directionality markers — that
render as nothing but encode where they got your address.

Common invisible characters to detect:

| Codepoint | Name | Typical use |
|-----------|------|------------|
| U+200B | Zero-width space | Hiding scrape source in "John<200b> Smith" |
| U+200C | Zero-width non-joiner | Same, sometimes used for fingerprinting |
| U+200D | Zero-width joiner | Emoji sequences, but also fingerprinting |
| U+FEFF | BOM / zero-width no-break space | Often a paste artifact or tracker |
| U+200E | Left-to-right mark | "John Smith<200e>" — invisible direction override |
| U+200F | Right-to-left mark | Same, opposite direction |
| U+2060 | Word joiner | Prevents line breaks; also used as a tracker |

Detection is a single regex — check whether the display name contains any of
these codepoints:

```python
INVISIBLE_CHARS = re.compile(
    "[\u200b-\u200f\u2028-\u2029\u202a-\u202e\u2060-\u2064\ufeff]"
)

def name_has_steganography(from_header: str, your_actual_name: str) -> bool:
    # Also check: does NFKC normalization change the string?
    # If so, something was hidden.
    return bool(INVISIBLE_CHARS.search(from_header))
```

This isn't a "spam" signal on its own — a legitimate company that bought a
scraped list still sends real order confirmations. The feature floats into
the model input and the model learns how much to weight it per category.

**Other features worth extracting:**

- **`List-Unsubscribe` header present** → binary feature, strong newsletter
  prior.
- **`Auto-Submitted` header** → `auto-replied`, `auto-generated`. Binary
  feature indicating automated mail.
- **Sender domain.** Map `from_domain` to a categorical feature. A small
  hand-curated list of high-signal domains (`@yourbank.com`, `@github.com`)
  gets explicit tokens; unknown domains get `domain=other`.
- **Time of day / day of week.** Work emails cluster in business hours;
  personal and newsletter mail doesn't. Two integer features the model can
  learn a prior over.

**Execution order in the pipeline:**

```
email arrives
    │
    ▼
[skip filter] ──skip?──▶ record skip:<reason> in DB, done
    │
    ▼
[envelope feature extraction] ──▶ encode features into model input
    │
    ▼
[LLM / classifier] ──▶ record label + confidence in DB
```

Features are extracted unconditionally for every non-skipped email and
encoded into the input. The model learns their weight during Phase 3
training.

---

## Phase 2: Review & Refinement

**Goal:** Audit the LLM's labels, fix errors, and arrive at a final taxonomy
worth training on.

This is the human bottleneck. The LLM will be wrong maybe 10-20% of the time
depending on how nuanced your categories are and how weird your email is. You
need a way to review corrections efficiently.

**Approach: stratified spot-check, not exhaustive review.**

1. Group by label, sample 50-100 emails from each category.
2. Review, mark misclassifications.
3. If a category has >15% error rate, investigate:
   - Is the label definition ambiguous? Split it.
   - Are two categories too similar? Merge them.
   - Is the model consistently wrong on a pattern? Add a pre-processing rule.
4. Adjust the taxonomy.
5. Spot-check again.

Exhaustive review of 50K emails is a recipe for never finishing. Stratified
sampling tells you where the problems are without reading everything.

**Refine the taxonomy based on what you actually receive.** The initial label
set was a guess. After seeing the data:

- Do you have 40% "newsletter" and 5% everything else? Split "newsletter" into
  sub-categories ("tech-newsletter", "product-update", "unsubscribe-target").
- Do "receipt" and "finance" overlap too much? Merge them.
- Are there labels with <1% of mail? Drop them into a parent category.

**Tooling:** A small review UI is worth it here. Could be as simple as a
terminal script that shows email subject + snippet + current label, asks for
correction (or Enter to accept). Could be a lightweight web UI if you prefer
clicking. Either way, write corrections back to the SQLite database with a
`reviewed_at` / `corrected_label` column so you can track what's been audited.

**Output:** A corrected dataset of `(email_text, final_label)` pairs, clean
taxonomy, and an idea of per-category accuracy of the LLM baseline.

---

## Phase 3: Train a Small Classifier

**Goal:** Replace the 7B LLM with a model small enough to run in <500MB,
responding in single-digit milliseconds.

**Why this works now:** You have a labeled dataset from Phase 2. A classifier
only needs to do one thing — map text to a known label — and small encoder
models do this extremely well once trained on in-domain data.

**Architecture options:**

| Approach | Model size | Training | Inference speed |
|----------|-----------|----------|-----------------|
| SetFit + paraphrase-multilingual-MiniLM-L12-v2 | ~120MB | Few-shot, works with 50-100 labels per class | <5ms |
| DistilBERT fine-tune + ONNX export | ~260MB | Full fine-tune, needs 500+ labels per class | <10ms |
| DeBERTa-v3-small fine-tune + ONNX export | ~180MB | Full fine-tune, stronger model | <15ms |

**Recommended: SetFit.**

[SetFit](https://huggingface.co/docs/setfit/index) is designed for exactly this
scenario — few-shot classification with sentence transformers. It works by:

1. Generating contrastive sentence embeddings from a small number of labeled
   examples per class.
2. Training a lightweight classification head on those embeddings.

It needs dramatically fewer examples than traditional fine-tuning (tens to low
hundreds per class, not thousands) and produces a model that exports cleanly to
ONNX. For a personal inbox taxonomy of 10-20 categories, you can train on a
laptop in under an hour.

**Training pipeline:**

```
corrected labels (SQLite) ──▶ stratified split (80/20) ──▶ SetFit training
                                                                │
                             ┌──────────────────────────────────┘
                             ▼
                    evaluate on held-out set
                             │
                             ▼
                    [acceptable accuracy?] ──no──▶ add more labeled examples, retry
                             │
                            yes
                             │
                             ▼
                    export to ONNX (quantized)
```

**What "acceptable accuracy" means:** The LLM baseline from Phase 1 is your
floor. The classifier should match or exceed it on the held-out test set.
SetFit with a few hundred examples per class typically hits 85-95% on narrow
classification tasks, which is usually better than a general 7B model guessing
from a prompt.

**Fallback path:** If SetFit doesn't work well (unusual taxonomy, very long
emails, heavy domain jargon), the next step is full fine-tuning of
DistilBERT/RoBERTa-base with the transformers `Trainer` API. More data-hungry,
but more powerful.

---

## Phase 4: Deploy the Classifier

**Goal:** A persistent, low-resource classification service that processes
incoming email in real time and applies labels.

**Architecture:**

```
[IMAP IDLE / periodic poll]
         │
         ▼
[Python classifier service]
   ├── ONNX Runtime (inference, ~300MB RAM)
   ├── IMAP client (fetch new mail)
   └── Label application (IMAP STORE or Gmail API)
```

**Deployment modes:**

**A. Cron job (simplest)**

Run every 1-5 minutes. Fetches unseen mail since last run, classifies, applies
labels. Works with any IMAP provider. Can be a `systemd` timer or a cron entry.
Downside: latency up to the polling interval.

**B. IMAP IDLE daemon (lower latency)**

Long-lived process that holds an IDLE connection, classifies within seconds of
arrival. Slightly more complex (IDLE timeouts, reconnection logic) but
responsive.

**C. Integration with existing mail client (most useful)**

If you use a mail client with extension support, classify server-side and let
the client's native filtering apply labels. Or use a Sieve script if your mail
provider supports it. Avoids fighting the client's own label logic.

**Model serving:**

- **ONNX Runtime** via `onnxruntime` Python package. Single `InferenceSession`,
  loaded once at startup. Thread-safe, trivial API.
- Model file: the quantized ONNX export from Phase 3 (~100-300MB).
- No GPU needed. CPU inference on a modern machine is <10ms per email for these
  model sizes.

**Monitoring (optional but useful):**

- Log label distribution weekly. If "newsletter" suddenly drops to zero, your
  taxonomy or the model might have drifted.
- Keep a random sample of classifications for periodic spot-check.
- Store the classifier's confidence score (softmax output) so you can flag
  low-confidence classifications for human review.

---

## Phase 5: Continuous Improvement

**Goal:** Keep the classifier accurate as your email patterns change, catch and
fix recurring mistakes, and make incremental model improvements without
rebuilding from scratch.

This is the phase that lasts years. The rest was setup. The design principle:
make corrections effortless at the point you notice them, batch the actual
retraining work, and never lose data.

### 5.1 Collecting corrections

You will find misclassifications. The trick is to capture them immediately,
before you forget, with zero friction.

**Per-classification confidence scores.** The ONNX classifier outputs a
softmax vector — one probability per label. Store the full vector, not just the
winner. This gives you:

- A threshold for flagging low-confidence classifications for review
- A way to discover *why* the model was torn between two labels
- A metric to track over time (is average confidence dropping?)

A reasonable approach: log the top-2 predicted labels and their scores.
If the gap between #1 and #2 is narrow (<0.3), that email goes into a
"needs review" bucket.

**Correction interface.** When you see a wrong label in your mail client,
you need a way to fix it that takes <5 seconds. Options from simplest to most
polished:

1. **Move to a different folder/label in your client.** A reconciliation
   script periodically scans for emails whose applied label doesn't match
   their folder location and records the correction.
2. **Reply-to-self convention.** Forward or bounce the email to yourself with
   a keyword in the subject like `[label: finance]`. A script picks these up,
   records the correction, and deletes the bounce.
3. **Small CLI or hotkey.** `fix-label <email-id> <correct-label>`.

The point is: whatever you pick, it must be faster than mentally grumbling
about it and moving on. If correction takes 30 seconds, you'll stop doing it
within a week.

**Store corrections in a dedicated table.** Keep them separate from the
original classification:

```sql
CREATE TABLE corrections (
    message_id TEXT PRIMARY KEY,
    original_label TEXT NOT NULL,
    corrected_label TEXT NOT NULL,
    corrected_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    model_version TEXT NOT NULL  -- which model got it wrong
);
```

This gives you a queryable error log. You can answer: "is model v3 worse than
v2 at distinguishing 'receipt' from 'finance'?"

### 5.2 When to retrain

Don't retrain on a schedule. Retrain when there's a reason. Triggers:

| Trigger | Threshold | Why |
|---------|-----------|-----|
| Accumulated corrections | 100+ new labeled examples | Enough signal to improve |
| New category needed | — | You notice a coherent cluster of emails getting consistently wrong labels |
| Category merge/split | — | Taxonomy change invalidates existing training data |
| Confidence drift | Average confidence drops >5% over a month | Model is losing grip on your mail |
| Distribution shift | Any category's share changes by >50% | Your mail patterns changed — e.g., new job, new subscriptions |

**Practical cadence:** For a personal inbox, you probably retrain every 1-3
months, or whenever you've accumulated enough corrections to bother. The
retraining script itself should be a single command — `python train.py` — that
reads the current SQLite state and outputs a new ONNX file.

### 5.3 The retraining workflow

```
SQLite ──▶ merge corrections into training set ──▶ retrain (same SetFit pipeline)
                                                        │
                         ┌──────────────────────────────┘
                         ▼
                evaluate on test set
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
      [better]      [same]         [worse]
          │              │              │
          ▼              ▼              ▼
      deploy         optional        investigate:
      new model      deploy          - too few examples?
                                     - conflicting labels?
                                     - taxonomy problem?
                                         │
                                         ▼
                                    fix data, retry
```

**Version the models.** Keep every trained model file with a version or date
stamp:

```
models/
  classifier-v1-2026-07-02.onnx
  classifier-v2-2026-08-15.onnx
  classifier-v3-2026-10-01.onnx
```

The deployment script loads from a symlink or a config key pointing at the
active version. Rolling back is changing that pointer and restarting — no
rebuild, no drama.

**Always evaluate against a fixed held-out set.** Split your data once in
Phase 3 and never add to the test set from corrections. The test set is your
honest benchmark. If you add corrected examples to it, you're grading on a
curve and you'll silently overestimate accuracy.

### 5.4 Handling taxonomy drift

Your mail isn't static. You change jobs, sign up for new services, unsubscribe
from newsletters. The label set needs to evolve.

**Adding a new category:**

1. Use the Phase 1 LLM to label a batch of emails with the *new* candidate
   label (prompt it with your updated taxonomy).
2. Review those labels manually.
3. Merge them into the training set.
4. Retrain from scratch — SetFit doesn't support incremental category
   addition, you need a fresh training run with the expanded label set.

**Merging two categories:**

Update the corrections table and training set to replace both old labels with
the merged label, then retrain. This is a pure data transform — no new
labeling needed.

**Splitting a category:**

Same as adding a new category — you need new labeled examples for the split.
The LLM is your labeling assistant here. Run it over all emails currently
labeled with the parent category, prompt it with the new sub-categories,
spot-check, retrain.

**Removing a dead category:**

If fewer than 0.5% of emails match a label and it's been declining for months,
consider merging it into a broader parent or marking it deprecated. The model
will waste capacity trying to learn a distinction that no longer matters.

### 5.5 Using the LLM as a fallback arbiter

Even after Phase 4, keep the LLM in your toolbox. It's useful for:

- **Low-confidence tiebreaking.** When the classifier's top-2 probability gap
  is <0.1, route that email to the LLM for a second opinion. The LLM is slower
  but can reason about ambiguous cases the classifier can't.
- **Validating retrained models.** Before deploying a new classifier version,
  run both the old and new model over a sample of recent emails and diff the
  disagreements. Spot-check a few to see if the new model is actually better.
- **Bootstrapping new categories.** The LLM is your labeler-of-first-resort
  when you need to seed a new category with examples.

This isn't about running the LLM continuously — it's about having it available
as a tool during retraining and for edge cases. The classifier handles the
99% of routine mail.

### 5.6 Monitoring that you'll actually see

The whole point of building this is to *reduce* email overhead. A log file
you never open is dead infrastructure. Push the signal to somewhere you
already look — Discord, in this case.

**Weekly digest to Discord: bar chart + summary stats.** A cron job that runs
once a week (Sunday evening, say) and posts a gnuplot-rendered bar chart of
label distribution plus a one-line correction-rate stat. You see it, you
acknowledge it, maybe you notice "huh, newsletters doubled this month" and
that's the whole interaction.

Script (`~/.local/bin/email-report`):

```bash
#!/usr/bin/env bash
set -euo pipefail

DB="${EMAIL_DB:-$HOME/.local/share/email-classifier/classifications.db}"
WEBHOOK="${EMAIL_DISCORD_WEBHOOK:-}"
WEEK_START=$(date -d '7 days ago' '+%Y-%m-%d')

if [ -z "$WEBHOOK" ]; then
    echo "EMAIL_DISCORD_WEBHOOK not set" >&2
    exit 1
fi

# --- query data ---

sqlite3 -separator $'\t' "$DB" \
    "SELECT label, COUNT(*) AS n
     FROM classifications
     WHERE classified_at >= '$WEEK_START'
     GROUP BY label
     ORDER BY n DESC;" > /tmp/email-labels.tsv

total=$(sqlite3 "$DB" \
    "SELECT COUNT(*) FROM classifications WHERE classified_at >= '$WEEK_START';")

corrections=$(sqlite3 "$DB" \
    "SELECT COUNT(*) FROM corrections WHERE corrected_at >= '$WEEK_START';")

if [ "$total" -eq 0 ]; then
    curl -s -H "Content-Type: application/json" -X POST "$WEBHOOK" \
        -d '{"content": "📭 No email classified this week."}'
    exit 0
fi

corr_pct=$(awk "BEGIN {printf \"%.1f\", ($corrections / $total) * 100}")

# --- gnuplot bar chart ---

gnuplot <<GNUPPLOT
set terminal pngcairo size 800,500 font 'Sans,10'
set output '/tmp/email-labels.png'
set style fill solid 0.85 border -1
set style data histogram
set style histogram cluster gap 1
set boxwidth 0.9
set xtics rotate by -45
set ylabel 'Emails'
set title 'Email Classification — week of $WEEK_START'
set key off
set grid ytics

plot '/tmp/email-labels.tsv' using 2:xtic(1) lc rgb '#5865F2'
GNUPPLOT

# --- push to Discord ---

summary="📊 **Weekly Email Report** ($WEEK_START → now)\n**$total** emails classified · **$corr_pct%** correction rate ($corrections fixed)"

curl -s -X POST "$WEBHOOK" \
    -F "content=$summary" \
    -F "file=@/tmp/email-labels.png" \
    -o /dev/null
```

**Cron entry:**

```
# Sunday 8pm — weekly email classification report
0 20 * * 0 EMAIL_DISCORD_WEBHOOK="https://discord.com/api/webhooks/..." /home/you/.local/bin/email-report
```

That's it. One shell script, gnuplot + sqlite3 + curl (all in your package
manager), fire-and-forget. If you want to check in, scroll up in the Discord
channel. If you don't, the chart scrolls away and nothing nags you.

**Correction rate as a canary.** The `corr_pct` line is the actual health
check. If it creeps from 1% to 5% to 8% over a few weeks, the model is
drifting and you should retrain. The bar chart is the nice-to-see context;
the correction rate is the thing that tells you something is wrong.

---

## Summary

```
Phase 1: 7B LLM + GBNF grammar → batch label entire backlog (SQLite)
Phase 2: Stratified spot-check → refine taxonomy → corrected dataset
Phase 3: SetFit on corrected data → ONNX export → bench against LLM baseline
Phase 4: ONNX Runtime + IMAP → real-time classification with <10ms latency
Phase 5: Corrections → accumulate → retrain → re-evaluate → redeploy (loop)
```

Key numbers at each stage:

| Phase | Model | RAM | Per-email time | Human effort |
|-------|-------|-----|---------------|--------------|
| 1 | 7B Q4 GGUF | ~6GB | 200ms-1s | ~30 min setup |
| 2 | — | — | — | 2-4 hours review |
| 3 | SetFit training | ~4GB | — | 1-2 hours |
| 4 | ONNX quantized | ~300MB | 5-10ms | ~1 hour deploy |
| 5 | ONNX + LLM fallback | ~300MB + LLM when needed | <10ms (classifier), ~500ms (LLM fallback) | ~5 min to fix a label, ~1 hour to retrain |
