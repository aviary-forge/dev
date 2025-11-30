{ dev, pkgs, ... }:

let
  naersk' = pkgs.callPackage dev.third_party.nix.naersk { };
  toolchain = pkgs.fenix.complete.toolchain;

in
naersk'.override {
  cargo = toolchain;
  rustc = toolchain;
}
