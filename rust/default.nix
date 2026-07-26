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
    hasPrefix
    hasSuffix
    removePrefix
    unique
    ;

  craneLib = pkgs.craneLib;

  # Workspace lives at repo root — crates can live anywhere under it
  repoRoot = ../.;
  repoRootStr = toString repoRoot;

  # Full workspace source — used for buildPackage where cargo needs every
  # member's real files for workspace resolution.
  workspaceSrc = craneLib.cleanCargoSource repoRoot;

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

  # Per-crate filtered source for cargoArtifacts (dep cache) only.
  # Includes all workspace Cargo.toml/Cargo.lock files for dep resolution,
  # plus this crate's source tree.  Directories from other workspace
  # members are kept (empty) so findCargoFiles can recurse through them
  # to discover their Cargo.toml files.
  mkCrateDepsSrc = memberPath:
    let
      crateRel = memberPath;
    in
    lib.cleanSourceWith {
      filter = path: type:
        let
          rel = removePrefix repoRootStr (toString path);
          norm = if hasPrefix "/" rel then removePrefix "/" rel else rel;
        in
        # Always allow directories so findCargoFiles can recurse
        (type == "directory")
        # Workspace toml/lock/config files
        || (hasSuffix "Cargo.toml" norm || hasSuffix "Cargo.lock" norm)
        || (hasSuffix ".cargo/config.toml" norm)
        # This crate's own source
        || (hasPrefix crateRel norm);
      src = repoRoot;
    };

  # Per-crate dependency cache.  The filtered source ensures that
  # unrelated source changes don't churn the dep compilation cache.
  # cargoArtifacts not churning means deps stay cached across pushes
  # that only touch other crates.
  mkCargoArtifacts = memberPath:
    craneLib.buildDepsOnly {
      src = mkCrateDepsSrc memberPath;
      pname = "${crateName memberPath}-deps";
      version = "0.1.0";
      strictDeps = true;
      buildInputs = mergedBuildInputs;
      nativeBuildInputs = mergedNativeBuildInputs;
    };

  # Build a single member.  cargoArtifacts is per-crate (doesn't churn
  # on unrelated changes).  src is the full workspace because cargo
  # needs all members' real files for workspace resolution when
  # building with -p.
  mkMember = memberPath:
    let
      name = crateName memberPath;
      override = loadOverride memberPath;
      # builtins.split returns empty lists for regex matches — filter
      # them out with builtins.isString to get just the path parts.
      parts = builtins.filter builtins.isString (builtins.split "/" memberPath);
    in
    craneLib.buildPackage ({
      cargoArtifacts = mkCargoArtifacts memberPath;
      src = workspaceSrc;
      pname = name;
      version = override.version or "0.1.0";
      cargoBuildExtraArgs = "-p ${name}";
      cargoTestExtraArgs = "-p ${name}";
      strictDeps = true;
      buildInputs = override.buildInputs or [ ];
      nativeBuildInputs = override.nativeBuildInputs or [ ];
      meta = override.meta or { };
    } // builtins.removeAttrs override [
      "buildInputs"
      "nativeBuildInputs"
      "version"
      "meta"
    ] // {
      __readTree = parts;
    });

  members = listToAttrs (map (mp: {
    name = crateName mp;
    value = mkMember mp;
  }) memberPaths);
in
members
// {
  __readTreeChildrenOverride = members;
}
