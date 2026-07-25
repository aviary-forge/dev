{ pkgs, lib, members, ... }:

let
  inherit (pkgs.stdenvNoCC.hostPlatform) isLinux;
in
{
  buildInputs = lib.optional isLinux pkgs.makeWrapper;

  nativeBuildInputs = with pkgs; [
    openssl.dev
    pkg-config
  ];

  postInstall = lib.optionalString isLinux ''
    wrapProgram $out/bin/gcroot-manager \
      --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.openssl ]}
  '';

  meta.owners = with members; [ denbeigh ];
}
