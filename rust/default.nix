{ pkgs, members, ... }@args:

let
  inherit (builtins)
    listToAttrs
    pathExists
    readFile
    ;

  # Parse workspace members from the root Cargo.toml
  workspaceToml = fromTOML (readFile ../Cargo.toml);
  memberPaths = workspaceToml.workspace.members or [ ];

  # Short crate name from a member path (e.g. "rust/gcroot-manager" -> "gcroot-manager")
  crateName = memberPath: baseNameOf memberPath;

  # Load a crate's optional overrides.nix.
  # Returns a function attrs -> attrs (crate2nix defaultCrateOverrides format)
  # or null if the file doesn't exist.
  loadOverride =
    memberPath:
    let
      p = ../${memberPath}/overrides.nix;
    in
    if pathExists p then import p args else null;

  # Build the crateOverrides map for crate2nix.
  # Keys are crate names; values are functions attrs -> attrs.
  crateOverrides =
    let
      hasOverride = memberPath: loadOverride memberPath != null;
      pathsWithOverrides = builtins.filter hasOverride memberPaths;
    in
    listToAttrs (
      map (mp: {
        name = crateName mp;
        value = loadOverride mp;
      }) pathsWithOverrides
    );

  # Wraps buildRustCrate with our overrides merged into nixpkgs' defaults
  mkBuildRustCrateForPkgs =
    pkgs:
    pkgs.buildRustCrate.override {
      defaultCrateOverrides = pkgs.defaultCrateOverrides // crateOverrides;
    };

  # Import the generated Cargo.nix
  cargo = pkgs.callPackage ./Cargo.nix {
    buildRustCrateForPkgs = mkBuildRustCrateForPkgs;
  };

  # Individual crate build derivations, keyed by crate name.
  # We set __readTree on each so CI sees the correct repo path
  # (e.g. tools/ci, not rust/ci).
  mkMember =
    memberPath:
    let
      name = crateName memberPath;
      drv = cargo.workspaceMembers.${name}.build;
      parts = builtins.filter builtins.isString (builtins.split "/" memberPath);
    in
    drv
    // {
      __readTree = parts;
      __readTreeChildren = [ ];
    };

  crates = builtins.listToAttrs (
    map (mp: {
      name = crateName mp;
      value = mkMember mp;
    }) memberPaths
  );

  # Script to regenerate Cargo.nix when deps change
  regenerate = pkgs.writeShellApplication {
    name = "generate-cargo-nix";
    runtimeInputs = with pkgs; [
      crate2nix
      git
    ];
    text = ''
      set -euo pipefail
      working_dir="$(git rev-parse --show-toplevel)"
      cargo_toml="$working_dir/Cargo.toml"
      output_path="$working_dir/rust/Cargo.nix"

      crate2nix generate \
        --cargo-toml "$cargo_toml" \
        --output "$output_path"
    '';

    meta.owners = with members; [ denbeigh ];
  };
in
crates
// {
  inherit regenerate;
  __readTreeChildrenOverride = crates // {
    inherit regenerate;
  };
}
