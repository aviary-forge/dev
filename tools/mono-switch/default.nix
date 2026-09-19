{
  dev,
  pkgs,
  lib,
  members,
  ...
}:
dev.python."mono-switch".overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
    pkgs.makeWrapper
    pkgs.python313Packages.pytest
  ];

  preCheck = (old.preCheck or "") + ''
    PYTHONPATH="$src" pytest -q tests
  '';

  postInstall = (old.postInstall or "") + ''
    wrapProgram $out/bin/mono-switch \
      --prefix PATH : ${
        lib.makeBinPath [
          pkgs.git
          pkgs.nix
        ]
      }
  '';

  meta = (old.meta or { }) // {
    owners = [ members.denbeigh ];
  };
})
