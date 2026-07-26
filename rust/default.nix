{ pkgs, lib, ... }@args:

let
  inherit (builtins)
    baseNameOf
    fromTOML
    listToAttrs
    map
    pathExists
    readFile
    ;
  inherit (lib)
    concatMap
    unique
    ;

  craneLib = pkgs.craneLib;

  # Workspace lives at repo root — crates can live anywhere under it
  repoRoot = ../.;
  src = craneLib.cleanCargoSource repoRoot;

  # Parse members from the root workspace Cargo.toml
  workspaceToml = fromTOML (readFile (repoRoot + "/Cargo.toml"));
  memberPaths = workspaceToml.workspace.members or [ ];

  # Short crate name from a member path (e.g. "rust/gcroot-manager" -> "gcroot-manager")
  crateName = memberPath: baseNameOf memberPath;

  # Load a crate's optional overrides.nix (lives next to its Cargo.toml)
  loadOverride = memberPath:
    let
      p = repoRoot + "/${memberPath}/overrides.nix";
    in
    if pathExists p then import p args else { };

  # All overrides keyed by crate name, used to merge build inputs for deps
  allOverrides = listToAttrs (map (mp: {
    name = crateName mp;
    value = loadOverride mp;
  }) memberPaths);

  mergedBuildInputs = unique (concatMap (o: o.buildInputs or [ ]) (builtins.attrValues allOverrides));
  mergedNativeBuildInputs = unique (concatMap (o: o.nativeBuildInputs or [ ]) (builtins.attrValues allOverrides));

  # Shared: all workspace dependencies, with per-crate build inputs merged in
  cargoArtifacts = craneLib.buildDepsOnly {
    inherit src;
    pname = "rust-workspace-deps";
    version = "0.1.0";
    strictDeps = true;
    buildInputs = mergedBuildInputs;
    nativeBuildInputs = mergedNativeBuildInputs;
  };

  # Build a single member, inheriting shared cargoArtifacts
  mkMember = memberPath:
    let
      name = crateName memberPath;
      override = loadOverride memberPath;
    in
    craneLib.buildPackage ({
      inherit cargoArtifacts src;
      pname = name;
      version = override.version or "0.1.0";
      cargoBuildArgs = "-p ${name}";
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

  members = listToAttrs (map (mp: {
    name = crateName mp;
    value = mkMember mp;
  }) memberPaths);
in
members
// {
  inherit cargoArtifacts;
  __readTreeChildrenOverride = members;
}
