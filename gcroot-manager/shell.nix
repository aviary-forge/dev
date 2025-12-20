{
  dev ? import ../. { },
}:

let
  pkgs = dev.third_party.nixpkgs;
  inherit (pkgs.stdenvNoCC.targetPlatform) isDarwin;
  inherit (pkgs.lib) optional;

  rustPkgs = with pkgs.fenix.complete; [
    toolchain
    rust-analyzer-preview
    rustfmt-preview
  ];

  macosPkgs = optional isDarwin (
    with pkgs;
    [
      pkg-config
      openssl.dev
      # for symbolbs in clippy check
      pkgs.stdenv.cc
    ]
  );
in
pkgs.mkShell {
  packages =
    rustPkgs
    ++ [
      dev.users.denbeigh.neovim
      pkgs.crate2nix
    ]
    ++ macosPkgs;
}
