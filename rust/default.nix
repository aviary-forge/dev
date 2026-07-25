{ pkgs, lib, ... }@args:

let
  inherit (builtins)
    mapAttrs
    pathExists
    readDir
    ;
  inherit (lib)
    filterAttrs
    ;

  craneLib = pkgs.craneLib;

  # Source filtered to just cargo-relevant files
  src = craneLib.cleanCargoSource ./.;

  # Load a crate's optional overrides.nix
  loadOverride = crateName:
    let
      p = ./${crateName}/overrides.nix;
    in
    if pathExists p then import p args else { };

  # Discover workspace members: directories containing a Cargo.toml
  memberDirs = filterAttrs
    (name: type: type == "directory" && pathExists ./${name}/Cargo.toml)
    (readDir ./.);

  # Collect build inputs from all overrides for the shared deps build
  allOverrides = mapAttrs (name: _: loadOverride name) memberDirs;
  mergedBuildInputs = lib.unique (lib.concatMap (o: o.buildInputs or [ ]) (builtins.attrValues allOverrides));
  mergedNativeBuildInputs = lib.unique (lib.concatMap (o: o.nativeBuildInputs or [ ]) (builtins.attrValues allOverrides));

  # Shared: all workspace dependencies compiled once, with deps from all overrides
  cargoArtifacts = craneLib.buildDepsOnly {
    inherit src;
    pname = "rust-workspace-deps";
    version = "0.1.0";
    strictDeps = true;
    buildInputs = mergedBuildInputs;
    nativeBuildInputs = mergedNativeBuildInputs;
  };

  # Build a single workspace member, inheriting shared cargoArtifacts
  mkMember = crateName:
    let
      override = loadOverride crateName;
    in
    craneLib.buildPackage ({
      inherit cargoArtifacts src;
      pname = crateName;
      version = override.version or "0.1.0";
      cargoBuildArgs = "-p ${crateName}";
      strictDeps = true;
      buildInputs = override.buildInputs or [ ];
      nativeBuildInputs = override.nativeBuildInputs or [ ];
      meta = override.meta or { };
    } // builtins.removeAttrs override [
      "buildInputs"
      "nativeBuildInputs"
      "version"
      "meta"
    ]);

  members = mapAttrs (name: _: mkMember name) memberDirs;
in
members
// {
  inherit cargoArtifacts;
  __readTreeChildrenOverride = members;
}
