{
  dev ? import ./. { },
}:

let
  pkgs = dev.third_party.nixpkgs;
  inherit (pkgs) lib;
in
pkgs.mkShell {
  packages = with pkgs; [
    stdenv.cc
    buildkite-cli
    nixfmt
    fenix.latest.rustfmt
    pre-commit
    uv
    ty
    ruff
    dev.tools.try
  ];

  shellHook = ''
    ${lib.getExe dev.tools.git-hooks.setup-pre-commit}
  '';
}
