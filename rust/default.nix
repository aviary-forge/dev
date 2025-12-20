{ pkgs, ... }@args:

let
  inherit (builtins)
    readDir
    listToAttrs
    map
    pathExists
    ;
  inherit (pkgs.lib)
    attrNames
    filterAttrs
    mapAttrs'
    nameValuePair
    ;

  # This allows us to specify overrides in an optional overrides.nix file in
  # the create's directory. In practice, most crates should specify this file,
  # because
  loadCrateOverride = crateName: (import ./${crateName}/overrides.nix args);
  crateHasOverride = crateName: pathExists ./${crateName}/overrides.nix;
  crateOverrides =
    let
      filter = name: value: (value == "directory" && crateHasOverride name);
      cratesWithOverrides = attrNames (filterAttrs filter (readDir ./.));
      mkOverride = crateName: nameValuePair crateName (loadCrateOverride crateName);

    in
    listToAttrs (map mkOverride cratesWithOverrides);

  mkCrateOverrides =
    pkgs:
    pkgs.buildRustCrate.override {
      defaultCrateOverrides = pkgs.defaultCrateOverrides // crateOverrides;
    };

  cargo = pkgs.callPackage ./cargo/default.nix {
    buildRustCrateForPkgs = mkCrateOverrides;
  };

  crates = builtins.mapAttrs (name: value: value.build) cargo.workspaceMembers;

  regenerate = pkgs.writeShellApplication {
    name = "generate-cargo-nix";
    runtimeInputs = with pkgs; [
      crate2nix
      git
    ];
    text = ''
      set -euo pipefail

      working_dir="$(git rev-parse --show-toplevel)/rust"
      cargo_toml="$working_dir/Cargo.toml"
      output_path="$working_dir/cargo/default.nix"

      crate2nix generate \
        --cargo-toml "$cargo_toml" \
        --output "$output_path"
    '';
  };
in
crates
// {
  inherit regenerate;
  # We don't really want to parse the subtree of all the crates in Nix,
  # but we do want to be able to gather these for use in CI etc
  __readTreeChildrenOverride = crates // {
    inherit regenerate;
  };
}
