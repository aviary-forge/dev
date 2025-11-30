{ dev, ... }:

let
  src = dev.third_party.nix.home-manager;
  cli = import src { pkgs = dev.third_party.nixpkgs; };
in
{ inherit src cli; }
