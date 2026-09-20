# tools/ci — CI Orchestrator

Rust binary that replaces `pre-build-pipeline-step`. Uses double
`nix eval` + drvPath diff to detect changed targets, then produces
one Buildkite step per system instead of one per target.

## Architecture

```
ci-orchestrator pipeline-gen   → Buildkite pipeline YAML (one step per system)
ci-orchestrator build          → nix-store --realise with @nix log parsing
ci-orchestrator post-build     → gcroot management, notifications (phase 2)
```

The Nix↔Rust interface is `tools/ci/drvmap.nix`:

```
nix eval --json -f tools/ci/drvmap.nix drvmap
→ { "tree/path": { "drvPath": "...", "attrPath": [...], "system": "...", ... } }
```

## Gotchas

### `cargoBuildArgs` is a no-op in crane

Crane's `buildPackage` and `buildDepsOnly` never consume `cargoBuildArgs`.
Use `cargoBuildExtraArgs` (appended to `cargo build`) and
`cargoTestExtraArgs` (appended to `cargo test`) instead.

Before (`rust/default.nix` — did nothing):

```nix
cargoBuildArgs = "-p ${name}";
```

After (actually scopes the build):

```nix
cargoBuildExtraArgs = "-p ${name}";
cargoTestExtraArgs = "-p ${name}";
```

### Fixpoint cycle in readTree default.nix

`tools/ci/default.nix` cannot access `args.dev` or `args.pkgs` during
readTree evaluation. The fixpoint `self` is still under construction when
children are imported. Accessing `self.rust.ci` (via `args.dev.rust.ci`)
creates a black hole. Accessing `args.pkgs` (which is
`self.third_party.nixpkgs`) triggers evaluation of nixpkgs overlays which
access `dev.third_party.nix` → same cycle.

**Solution**: `tools/ci/default.nix` is a thin placeholder that returns
`__readTreeChildrenOverride = {}`. The actual binary build goes through the
shared crane workspace at `dev.rust.ci`.

### Unit tests need files not in crane-filtered source

Crane's `cleanCargoSource` filters to Rust-relevant files only. `.nix` files
and `.git` directories are excluded from the source tree used in Nix builds.
Unit tests that depend on these resources must skip gracefully:

- `test_drvmap_expr_exists` — `drvmap.nix` not in filtered source
- `test_merge_base_self` — no `.git` directory in the sandbox

### `nix-instantiate --json` requires derivations

The original plan used `nix-instantiate --json -A ci.targets`, but
`nix-instantiate --json` only outputs JSON for derivation sets. A plain
attrset (like the drvmap) causes "expression does not evaluate to a
derivation". Use `nix eval --json -f` instead.

### `nix eval` uses cwd, `import ./.` is file-relative

`import ./.` in a Nix file resolves relative to the FILE's directory, not
cwd. `tools/ci/drvmap.nix` uses `import ../..` to reach the repo root.
The Rust binary's `--repo-root` flag controls where `nix eval` is executed,
but the internal imports are always file-relative.

### readTree args flow depends on `default.nix` import style

When `import ./. {}` is called, readTree receives `{ localSystem ? ... }`
(no `dev`, no `pkgs`). `dev` and `pkgs` are only available in children
because `default.nix` constructs them via the fixpoint and passes them to
`readRepo`. External callers like `drvmap.nix` get them from the import
result but children see them in their readTree args.

### `third_party/opam2nix` is experimental

This directory has a `.skip-subtree` to prevent readTree from importing it.
It contains an opam2nix experiment that isn't readTree-compatible.

### drvmap.nix doesn't exist at the base commit

The double-instantiation algorithm creates a git worktree at the merge-base
commit, then runs `nix eval -f tools/ci/drvmap.nix drvmap` in it. But
`tools/ci/drvmap.nix` was created on this branch — it doesn't exist on trunk.

**Solution**: `instantiate.rs` copies `drvmap.nix` from the current checkout
into the worktree before evaluating. The file's internal `import ../..`
resolves relative to its physical location, so placing it in the worktree
ensures it picks up the base commit's Nix code. This works because:

1. The file's function signature has `dev ? import ../.. {}` — since
   `nix eval` calls it without args, `dev` defaults to importing the
   worktree root.
2. The worktree root's readTree discovers the copied file as a child of
   `tools/`, but that's harmless — `drvmap.nix` gets the fixpoint `dev`
   from readTree args and doesn't recurse.

### Generated pipeline step keys must not collide with static pipeline

The static `pipelines/default.yaml` already owns keys like `pipeline-gen`,
`:point_up:`, and `:arrow_heading_down:`. The Rust binary's generated
pipeline must not reuse these keys. Currently it emits:

- `build-{system}` (per-system, no collision)
- `ci-post-build` (no collision)

### Binary is not on PATH in Buildkite steps

The `ci-orchestrator` binary is built by `nix-build` and lives in the Nix
store. Pipeline step commands must wrap it:

```bash
"$(nix-build -A pipelines.tasks.ci-orchestrator)/bin/ci-orchestrator" <subcommand>
```

### drvmap cache for merge-base parent

`pipeline-gen` caches the parent drvmap by `{base_commit_sha}.json` in
`/var/cache/ci-orchestrator/drvmap-cache/` (overridable via
`CI_DRVMAP_CACHE_DIR`).  The first push to a branch evaluates the parent
(the expensive worktree + `nix eval`); subsequent pushes to branches
sharing the same merge-base hit the cache and skip straight to the diff.

**Cache invalidation**: the current checkout's `tools/ci/drvmap.nix`
content is stored alongside each cache entry.  If the entry point
changes between pushes, the old cached entry is treated as stale and
re-evaluated.  The base commit's Nix code is already pinned by the
commit SHA — no need to hash the entire worktree.

**Buildkite artifact fallback** (`src/buildkite.rs`): on a local cache miss,
pipeline-gen queries the Buildkite GraphQL API for recent trunk builds (last
50, states RUNNING/PASSED) whose `pipeline-gen` step uploaded
`pipeline/drvmap.json`, and accepts the first build whose **commit exactly
matches the merge-base SHA**.drvPath diffing requires identical evaluation
inputs, so a merely-close commit would spuriously mark everything changed —
no fuzzy matching. The artifact is validated the same way as the local cache:
`git show <commit>:tools/ci/drvmap.nix` must byte-equal the current checkout's
entry point. On a hit, the map is also stored into the local cache so later
pushes skip the GraphQL round trip. Falls through to the worktree eval on any
error. Requires `BUILDKITE_ORGANIZATION_SLUG`/`BUILDKITE_PIPELINE_SLUG` (set
on Buildkite agents) and the API token at `BUILDKITE_TOKEN_PATH` (default
`~/buildkite-token`) — same convention as the legacy `fetch-parent-targets`
task, which this replaces.

**Trunk caching**: When `BUILDKITE_BRANCH` is `"trunk"`, the
orchestrator also caches the HEAD drvmap under its own commit SHA (via
`git rev-parse HEAD`).  This way a feature branch whose merge-base is
that exact commit gets a cache hit without any worktree + eval round
trip.  Trunk-side caching is done *after* the normal parent-diff flow
— it's additive, not a replacement.

**Multitenancy**: Buildkite agents run under different Unix users. The
NixOS module (`modules/ci/nixos.nix`) provisions the cache directory via
a systemd tmpfiles rule — `2775 root ci-agents` (setgid, group-owned) —
so no manual setup is required on agent machines:

### Pending targets must be resolved against outputs, not the .drv path

When `nix-store --realise` fails, `realise.rs` must decide whether each
still-pending target was already built or skipped by `--keep-going`.
`Path::exists()` on the entry's `drv_path` is always true — .drv files are
written during instantiation, before realisation — so a dependency failure
in a third-party drv (not in the drvmap) used to launder every skipped
dependent into "succeeded" and report overall success despite nix-store
exiting non-zero. Pending targets are now resolved by checking the
derivation's output paths (`nix-store --query --outputs`) instead, and
overall success requires every target to be "succeeded" ("skipped" fails
the build).

### --log-format internal-json floods Buildkite logs

`nix-store --realise --log-format internal-json` streams one `@nix {...}`
JSON object per line to stderr, which Buildkite captures. Until
`ci-orchestrator build` mode is wired in to parse this stream and emit
Buildkite annotations, the flag is omitted from the build command.
When it's re-enabled, stderr should be piped through `ci-orchestrator`
(or to a file) rather than going directly to the Buildkite log.
