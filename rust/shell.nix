{
  dev ? import ../. { },
}:

let
  pkgs = dev.third_party.nixpkgs;
in
pkgs.mkShell {
  packages = [
    pkgs.fenix.complete.toolchain
    pkgs.crate2nix

    dev.rust.regenerate
  ];
}
