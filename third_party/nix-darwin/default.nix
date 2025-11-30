{ dev, pkgs, localSystem, ... }:
{ configuration
, specialArgs ? { }
, system ? localSystem
, ...
}:
let
  initConfig.nixpkgs = {
    inherit system;
    source = dev.third_party.nixpkgs;
  };

  # I don't believe this is subject to the same evaluation-time recursion
  # limitations as nixos...but we shall see.
  eval = import (dev.third_party.nix-darwin.path + "/eval-config.nix") {
    inherit (pkgs) lib;
    modules = [
      configuration
      initConfig
    ];
    inherit system;
    specialArgs = specialArgs // { inherit dev; };
  };
in
{ inherit eval; }
