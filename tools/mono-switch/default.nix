{ pkgs, members, ... }:

pkgs.python3.pkgs.buildPythonApplication {
  name = "mono-switch";
  format = "pyproject";

  src = ./.;

  nativeBuildInputs = [
    pkgs.makeWrapper
    pkgs.python3Packages.setuptools
  ];

  postInstall = ''
    wrapProgram $out/bin/mono-switch \
      --prefix PATH : ${
        pkgs.lib.makeBinPath [
          pkgs.git
          pkgs.nix
        ]
      }
  '';

  meta = {
    owners = [ members.denbeigh ];
  };
}
