{
  dev,
  pkgs,
  lib,
  members,
  ...
}:
(dev.python."mono-switch").overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
    pkgs.makeWrapper
  ];

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
