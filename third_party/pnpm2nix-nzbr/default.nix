{ pkgs, dev, ... }:
pkgs.callPackage "${dev.third_party.nix."pnpm2nix-nzbr"}/derivation.nix" { }
