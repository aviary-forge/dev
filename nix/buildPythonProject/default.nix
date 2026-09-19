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
# Wraps pyproject.nix's mkApplication to produce a clean derivation from the
# shared workspace pythonSet, with ruff lint/format and ty type-checking
# enforced in the check phase. The ruff baseline lives in the repo-root
# ruff.toml (see ruffToml below).
{
  # pyproject.nix package derivation (from the workspace pythonSet)
  package,
  # Virtualenv containing the package and its deps
  venv,
  # Source tree for static analysis — must contain a pyproject.toml
  src,
  # stdenv defaults doCheck off and mkApplication doesn't force it on, so
  # without this the whole checkPhase silently never runs.
  doCheck ? true,
  # Extra packages for the check phase (e.g. mypy, pytest)
  nativeCheckInputs ? [ ],
  # Baseline ruff config (the repo-root ruff.toml). src is the member dir
  # alone, so discovery can't see the repo root — pass --config instead.
  # Location-safe because known-first-party in the baseline wins before
  # isort's config-dir-relative src matching.
  ruffToml ? null,
  # Extra known-first-party entries beyond the root ruff.toml list.
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

  # Config copy in $TMPDIR; store paths are read-only.
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
        chmod u+w "$checkCfg"  # store copy is mode 444
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
    # $src is read-only; redirect the check tools' writes (ruff/pytest
    # caches, bytecode) to $TMPDIR and run in place. Details:
    # docs/buildPythonProject-checkphase-caches.md
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
