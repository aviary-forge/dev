{
  dev ? import ../.. { },
}:

let
  pkgs = dev.third_party.nixpkgs;
  inherit (pkgs.stdenvNoCC.hostPlatform) isDarwin;

  rustPkgs = with pkgs.fenix.complete; [
    toolchain
    rust-analyzer-preview
    rustfmt-preview
  ];

  macosPkgs = pkgs.lib.optionals isDarwin (
    with pkgs;
    [
      pkg-config
      openssl.dev
      stdenv.cc
    ]
  );
in
pkgs.mkShell {
  inputsFrom = [ dev.rust.gcroot-manager ];
  packages = rustPkgs ++ macosPkgs;
}
