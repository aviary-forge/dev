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
rec {
  # Standardised Python project builder.
  #
  # Wraps pyproject.nix's mkApplication to produce a clean derivation from a
  # shared workspace pythonSet, with ruff lint/format checks enforced during
  # the check phase.
  #
  # Every Python tool in the monorepo gets formatting + lint enforcement
  # automatically — no separate derivation needed, no double-build cost.
  #
  # A pyproject.toml at the repo root provides the ruff config baseline;
  # individual projects can override via their own pyproject.toml.
  buildPythonProject =
    {
      # pyproject.nix package derivation (from the workspace pythonSet)
      package,
      # Virtualenv containing the package and its deps
      venv,
      # Source tree for static analysis — must contain a pyproject.toml
      src,
      # Extra packages for the check phase (e.g. mypy, pytest)
      nativeCheckInputs ? [ ],
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
    in
    app.overrideAttrs (old: {
      inherit src;

      nativeCheckInputs = (old.nativeCheckInputs or [ ]) ++ [ pkgs.ruff ] ++ nativeCheckInputs;

      preCheck = ''
        echo "⟳  Checking ruff…"
        cd "$src"
        ruff check .
        ruff format --check .
      ''
      + lib.optionalString (preCheck != "") ''

        ${preCheck}'';

      postCheck = postCheck;

      passthru = (old.passthru or { }) // passthru // { inherit package venv; };

      meta = (old.meta or { }) // (attrs.meta or { });
    });
}
