# pi-extensions-update

Manages the nix-packaged pi extensions in `third_party/pi-extensions`:
discovery of `mkPiPackage` packages, version bumps against the npm registry,
and the tarball-hash / lockfile / `npmDepsHash` pipeline that hand-editing
gets wrong.

Pin state lives in three places per package: `versions.json` (shared version
truth), `<pkg>/default.nix` (`srcHash` + `npmDepsHash`), and the vendored
`<pkg>/package-lock.json`. Full design and validated mechanics:
[`docs/pi-extensions-update-tool.md`](../../docs/pi-extensions-update-tool.md).

## Invocation

Stdlib-only Python; the nix wrapper puts `git`, `nix`, `nodejs`/npm and
`prefetch-npm-deps` (all from the repo-pinned nixpkgs) on PATH:

```
nix shell -f . tools.pi-extensions-update --command pi-extensions-update status
nix-build -A tools.pi-extensions-update   # then run ./result/bin/pi-extensions-update
```

## Subcommands

### `status` — pinned vs registry-latest vs ad-hoc-installed

```
pi-extensions-update status
```

Table of `package | pinned | latest | installed` for every discovered
package. "installed" is read from `~/.pi/agent/npm/node_modules` (absent →
`-`). Read-only; exits 0.

### `update` — bump packages

```
pi-extensions-update update [names...] [--all] [--version V] [--no-build]
```

Targets registry `dist-tags.latest` by default; `--version V` pins
explicitly. Names are directory names or npm names; no names and no `--all`
is an error. Packages are processed sequentially (nix builds contend on
shared caches/locks); a per-package failure does not abort the batch — the
tree is left dirty for inspection and a `git diff --stat` summary prints at
the end.

Exit codes: 0 all bumped cleanly; 1 at least one package failed; 2 usage /
dirty-tree precondition errors.

### `add` — add a new package from an npm name

```
pi-extensions-update add <npm-name> [--version V] [--dir NAME] [--no-build]
```

Fetches registry metadata (default: latest version), creates
`<dir>/default.nix` from `pi_extensions_update/package-template.nix.in` (kept off the .nix suffix so nixfmt/statix skip its @@placeholders@@)
(pi-intercom-shaped), regenerates the lockfile, computes both hashes, builds
to verify, and appends to `versions.json`. `--dir` defaults to the npm name
minus any `@scope/` prefix.

Exit codes: 0 success; 1 validation or pipeline failure (name already
present, registry error, build failure).

### `check` — CI-able staleness gate

```
pi-extensions-update check [--against {latest,installed}]
```

Compares every pin to registry latest (default) or the ad-hoc-installed
versions. Exit codes: 0 all pins current; 1 at least one stale (missing
ad-hoc install counts as stale with `<not installed>`); 2 the check itself
could not run (registry fetch failure, unreadable `versions.json`) — a
partial failure never masquerades as clean.

## Steps the tool deliberately leaves to you

- **`add`'s TODO(human) comment block**: the tool cannot infer a package's
  runtime deps, lifecycle scripts, or load-time quirks. It inserts a
  placeholder; fill it in (pi-intercom's `default.nix` is the reference).
- **Smoke-testing a built package**: load `<out>/lib/pi-package` under `pi`
  with the wrapped host agent. Not automated.
- **`sync` from ad-hoc-installed versions** is not a command; `update
  --version X` covers it manually.
