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
  ];

  shellHook = ''
    ${lib.getExe dev.tools.git-hooks.setup-pre-commit}
  '';
}
