{ pkgs, members, ... }:

let
  inherit (pkgs.stdenvNoCC.targetPlatform) isLinux;
  inherit (pkgs.lib) optional;
in

attrs: {
  buildInputs = optional isLinux pkgs.makeWrapper;
  postInstall =
    let
      inherit (pkgs.lib) optionalString makeLibraryPath;
      libPath = makeLibraryPath [ pkgs.openssl ];
    in
    optionalString isLinux ''
      wrapProgram $out/bin/gcroot-manager --prefix LD_LIBRARY_PATH : ${libPath}
    '';
  runtimeInputs = [ pkgs.openssl.dev ];

  meta.owners = with members; [ denbeigh ];
}
