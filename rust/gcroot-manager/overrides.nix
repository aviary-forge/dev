{
  pkgs,
  lib,
  members,
  ...
}:

let
  inherit (pkgs.stdenvNoCC.hostPlatform) isLinux;
in
attrs: {
  buildInputs =
    (attrs.buildInputs or [ ]) ++ [ pkgs.openssl ] ++ lib.optional isLinux pkgs.makeWrapper;

  nativeBuildInputs = (attrs.nativeBuildInputs or [ ]) ++ [ pkgs.pkg-config ];

  postInstall =
    (attrs.postInstall or "")
    + lib.optionalString isLinux ''
      wrapProgram $out/bin/gcroot-manager \
        --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.openssl ]}
    '';

  meta = (attrs.meta or { }) // {
    owners = with members; [ denbeigh ];
  };
}
