{ pkgs, ... }:

let
  inherit (pkgs.stdenvNoCC.targetPlatform) isLinux;
  inherit (pkgs.lib) optional;

  overrideAttrs = attrs: {
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

  };

  customBuildCrate =
    pkgs:
    pkgs.buildRustCrate.override {
      defaultCrateOverrides = pkgs.defaultCrateOverrides // {
        "gcroot-manager" = overrideAttrs;
      };
    };

  cargo = pkgs.callPackage ./Cargo.nix {
    buildRustCrateForPkgs = customBuildCrate;
  };
in
cargo.rootCrate.build
