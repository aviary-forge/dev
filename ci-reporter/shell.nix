{ dev ? import ../. { } }:

let
  pkgs = dev.third_party.nixpkgs;
in
pkgs.mkShell {
  packages = [
    pkgs.fenix.complete.toolchain
    pkgs.fenix.complete.rust-analyzer-preview
    pkgs.fenix.complete.clippy
    dev.users.denbeigh.neovim
  ];
}
