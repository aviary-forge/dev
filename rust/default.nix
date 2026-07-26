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
  crateName = baseNameOf;

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

  # Script to regenerate Cargo.nix when deps change.
  #
  # Without --check: runs crate2nix and prepends a Cargo.lock checksum header
  # so future --check runs can skip redundant regeneration.
  #
  # With --check: compares the embedded checksum against the current Cargo.lock
  # and exits non-zero if they differ — no generation, just verification.
  regenerate = pkgs.writeShellApplication {
    name = "generate-cargo-nix";
    runtimeInputs = with pkgs; [
      coreutils
      crate2nix
      git
    ];
    text = ''
      set -euo pipefail
      working_dir="$(git rev-parse --show-toplevel)"
      cargo_lock="$working_dir/Cargo.lock"
      output_path="$working_dir/rust/Cargo.nix"

      if [ "''${1:-}" = "--check" ]; then
        expected=$(sed -n 's/^# Cargo\.lock sha256: //p' "$output_path" | head -1)
        if [ -z "$expected" ]; then
          echo "error: Cargo.nix is missing the Cargo.lock checksum header — regenerate with: nix run .#rust.regenerate" >&2
          exit 1
        fi
        actual=$(sha256sum "$cargo_lock" | cut -d' ' -f1)
        if [ "$expected" != "$actual" ]; then
          echo "Cargo.nix is out of date (Cargo.lock changed). Run: nix run .#rust.regenerate" >&2
          exit 1
        fi
        echo "Cargo.nix is up-to-date" >&2
        exit 0
      fi

      cd "$working_dir"
      crate2nix generate \
        --cargo-toml Cargo.toml \
        --output rust/Cargo.nix

      checksum=$(sha256sum "$cargo_lock" | cut -d' ' -f1)
      tmp="$(mktemp)"
      {
        echo "# Cargo.lock sha256: $checksum"
        cat "$output_path"
      } > "$tmp"
      mv "$tmp" "$output_path"

      echo "Cargo.nix regenerated (Cargo.lock sha256: $checksum)" >&2
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
