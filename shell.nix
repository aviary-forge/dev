{
  dev ? import ./. { },
}:

let
  pkgs = dev.third_party.nixpkgs;
  inherit (pkgs) lib;
in
pkgs.mkShell {
  packages = [
    pkgs.stdenv.cc
    pkgs.buildkite-cli
    pkgs.nixfmt
    pkgs.fenix.latest.rustfmt
    pkgs.pre-commit
  ];

  shellHook = ''
    ${lib.getExe dev.tools.git-hooks.setup-pre-commit}
  '';
}
