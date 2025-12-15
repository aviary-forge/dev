{ dev, pkgs, ... }:

let
  inherit (pkgs.stdenvNoCC.targetPlatform) isLinux;
  inherit (pkgs.lib) optional;
in

dev.third_party.naersk.buildPackage {
  src = ./.;

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
}
