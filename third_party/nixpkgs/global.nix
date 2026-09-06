# Shim for using the monorepo's pinned, overlaid nixpkgs as the global
# "<nixpkgs>" (e.g. via NIX_PATH=nixpkgs=<path to this file>), so that
# ad-hoc tooling (nix-shell -p, nix-build '<nixpkgs>', nix-env -iA, ...)
# resolves to the same package set the systems are built from.
#
# Deliberately independent of the readTree fixpoint: this file only touches
# ./default.nix and the niv pins in //third_party/nix, so it can be evaluated
# from any context (user shells, CI, non-managed machines) without forcing
# the rest of the repository.
#
# Usage: import <nixpkgs> { overlays = [ ... ]; config = { ... }; }
{
  # override the niv pin set if needed (defaults to //third_party/nix)
  pins ? import ../nix { },
  overlays ? [ ],
  config ? { },
  localSystem ? builtins.currentSystem,
  crossSystem ? localSystem,
  devOverlays ? true,
}:
import ./default.nix {
  inherit pins devOverlays;
  additionalOverlays = overlays;
  externalArgs = {
    nixpkgsConfig = config;
    inherit localSystem crossSystem;
  };
}
