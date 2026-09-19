{
  dev,
  pkgs,
  lib,
  members,
  ...
}:
dev.python."pi-extensions-update".overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
    pkgs.makeWrapper
    pkgs.python313Packages.pytest
  ];

  preCheck = (old.preCheck or "") + ''
    PYTHONPATH="$src" pytest -q tests
  '';

  postInstall = (old.postInstall or "") + ''
    wrapProgram $out/bin/pi-extensions-update \
      --prefix PATH : ${
        lib.makeBinPath [
          pkgs.git
          pkgs.nix
          pkgs.nodejs
          pkgs.prefetch-npm-deps
        ]
      }
  '';

  meta = (old.meta or { }) // {
    owners = [ members.denbeigh ];
  };
})
