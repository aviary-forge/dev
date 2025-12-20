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

  # We don't really want to parse the subtree of all the crates in Nix,
  # so after building we just tack on fake __readTree attrs for each
  # crate to make them look behave consistently with real targets.
  addReadTree =
    attrs:
    let
      mkEnt = name: {
        __readTree = [
          "rust"
          name
        ];
        __readTreeChildren = [ ];
      };

      patchValue = name: value: value // (mkEnt name);
    in
    mapAttrs' (n: v: nameValuePair n (patchValue n v)) attrs;
  pluckBuild = name: value: (nameValuePair name value.build);

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
addReadTree ((mapAttrs' pluckBuild cargo.workspaceMembers) // { inherit regenerate; })
