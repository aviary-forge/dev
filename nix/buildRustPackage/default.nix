{ pkgs, lib, ... }:

let
  inherit (pkgs) craneLib;
in
# Standardised Rust package builder.
#
# Wraps craneLib.buildPackage to enforce cargo fmt --check during the
# check phase. Every Rust crate in the monorepo gets formatting
# enforcement automatically — no separate derivation needed, no
# double-compilation cost.
#
# If a rustfmt.toml exists at the repo root, it is automatically
# included by crane's filterCargoSources (which keeps all .toml files).
attrs:
craneLib.buildPackage (
  attrs
  // {
    nativeCheckInputs = (attrs.nativeCheckInputs or [ ]) ++ [ pkgs.rustfmt ];

    preCheck = ''
      echo "⟳  Checking rustfmt…"
      cargo fmt -- --check
    ''
    + lib.optionalString ((attrs.preCheck or "") != "") "\n"
    + (attrs.preCheck or "");
  }
)
