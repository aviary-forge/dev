# Non-flake integration: bypasses flake-compat entirely so evaluation
# doesn't require network access (fetchTree). Works in restricted eval.
{ dev, pkgs, lib, localSystem ? builtins.currentSystem, ... }:

let
  nixvimSrc = dev.third_party.nix.nixvim.outPath;

  # Extend nixpkgs lib with nixvim's overlay (the public non-flake entry point)
  nixvimLib = (lib.extend (import (nixvimSrc + "/lib/overlay.nix"))).nixvim;

  # Build per-system packages. The standalone wrapper accepts a `system`
  # parameter (defaulting to `defaultSystem`), so these work for any system.
  mkNixvimPackages = system:
    let
      makeNixvimWithModule = import (nixvimSrc + "/wrappers/standalone.nix") {
        inherit lib;
        inherit (nixvimLib) evalNixvim;
        defaultSystem = system;
      };
    in
    {
      inherit makeNixvimWithModule;
      makeNixvim = module: makeNixvimWithModule { inherit module; };
    };

in
{
  inherit (nixvimLib) lib;
  legacyPackages = { ${localSystem} = mkNixvimPackages localSystem; };
}
