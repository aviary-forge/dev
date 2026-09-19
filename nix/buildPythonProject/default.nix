{
  dev,
  pkgs,
  lib,
  ...
}:

let
  pyproject-nix = dev.third_party."pyproject-nix";
  inherit (pkgs.callPackages pyproject-nix.build.util { }) mkApplication;
in
# Standardised Python project builder.
#
# Wraps pyproject.nix's mkApplication to produce a clean derivation from a
# shared workspace pythonSet, with ruff lint/format and ty type-checking
# enforced during the check phase.
#
# Every Python tool in the monorepo gets formatting + lint enforcement
# automatically — no separate derivation needed, no double-build cost.
#
# A pyproject.toml at the repo root provides the ruff config baseline;
# individual projects can override via their own pyproject.toml.
{
  # pyproject.nix package derivation (from the workspace pythonSet)
  package,
  # Virtualenv containing the package and its deps
  venv,
  # Source tree for static analysis — must contain a pyproject.toml
  src,
  # Run the checkPhase (ruff + ty + caller preCheck). Defaults on — stdenv
  # would otherwise silently skip the entire phase (pyproject.nix's
  # mkApplication doesn't force it on). Projects may set false to opt out.
  doCheck ? true,
  # Extra packages for the check phase (e.g. mypy, pytest)
  nativeCheckInputs ? [ ],
  # Optional path to a baseline ruff config (e.g. the repo-root ruff.toml).
  # src is the member directory alone, so ruff's upward discovery in the
  # build can't see the repo root — this file is passed via --config
  # instead (materialized to $TMPDIR, patched with firstPartyModules if
  # set). With known-first-party pinned, --config is location-safe: the
  # explicit list wins before isort's config-dir-relative src matching.
  ruffToml ? null,
  # Extra module names for the generated [lint.isort] known-first-party
  # section (normally unnecessary — the root ruff.toml keeps the list).
  firstPartyModules ? [ ],
  # Shell snippet to run before ruff checks
  preCheck ? "",
  # Shell snippet to run after ruff checks
  postCheck ? "",
  # Passthru attributes merged into derivation
  passthru ? { },
  ...
}@attrs:
let
  app = mkApplication { inherit venv package; };

  isortToml = lib.optionalString (firstPartyModules != [ ]) ''
    [lint.isort]
    known-first-party = [${lib.concatStringsSep ", " (map (m: "\"" + m + "\"") firstPartyModules)}]
  '';

  # Materialize the baseline ruff config into $TMPDIR (optionally patched
  # with extra first-party modules) for --config. No copy of $src is
  # needed: with cache redirection + PYTHONDONTWRITEBYTECODE + the pytest
  # cacheprovider disabled, all check tools run read-only in place
  # (docs/buildPythonProject-checkphase-caches.md).
  materializeRuffConfig =
    if ruffToml == null then
      if isortToml != "" then
        throw "buildPythonProject: firstPartyModules set without ruffToml — no baseline config to patch"
      else
        ""
    else
      ''
        checkCfg="$TMPDIR/ruff-check.toml"
        cp ${ruffToml} "$checkCfg"
      ''
      + lib.optionalString (isortToml != "") ''
        # The copied config inherits the store's read-only mode (444).
        chmod u+w "$checkCfg"
        cat >> "$checkCfg" <<'ISORT_EOF'
        ${isortToml}ISORT_EOF
      '';
  ruffConfigArgs = lib.optionalString (ruffToml != null) ''--config "$checkCfg"'';
in
app.overrideAttrs (old: {
  inherit src;

  inherit doCheck;

  nativeCheckInputs =
    (old.nativeCheckInputs or [ ])
    ++ [
      pkgs.ruff
      pkgs.ty
    ]
    ++ nativeCheckInputs;

  preCheck = ''
    # $src is a read-only store path, and the check tools want to write into
    # the tree they check. Instead of copying the tree, redirect every
    # writer to $TMPDIR and run in place (evidence + tool-by-tool breakdown:
    # docs/buildPythonProject-checkphase-caches.md). --config points at the
    # baseline ruff config rather than relying on discovery, which cannot
    # see the repo root from inside the member store path.
    ${materializeRuffConfig}
    cd "$src"
    export RUFF_CACHE_DIR="$TMPDIR/ruff-cache"
    export XDG_CACHE_HOME="$TMPDIR/xdg-cache"
    export PYTHONDONTWRITEBYTECODE=1
    export PYTEST_ADDOPTS="-p no:cacheprovider"

    ruff check . ${ruffConfigArgs}
    ruff format --check . ${ruffConfigArgs}

    ty check .
  ''
  + lib.optionalString (preCheck != "") ''

    ${preCheck}'';

  inherit postCheck;

  passthru = (old.passthru or { }) // passthru // { inherit package venv; };

  meta = (old.meta or { }) // (attrs.meta or { });
})
