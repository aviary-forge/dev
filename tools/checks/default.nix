{
  dev,
  pkgs,
  lib,
  ...
}:

let
  inherit (builtins) elem;
  inherit (pkgs) runCommand nixfmt-rfc-style;

  # Source filtered to only .nix files so this derivation only
  # rebuilds when .nix files change. Also excludes common build
  # artifact directories that cleanSourceFilter misses.
  nixSource = lib.cleanSourceWith {
    name = "nix-source";
    src = dev.path;
    filter =
      path: type:
      let
        base = baseNameOf path;
      in
      (lib.cleanSourceFilter path type)
      && (
        type == "directory"
        -> !(elem base [
          "_build" # dune/OCaml build artifacts
          "target" # Rust build artifacts
          "node_modules"
        ])
      )
      && (type == "directory" || lib.hasSuffix ".nix" path);
  };
in
{
  # Nix formatting check.
  #
  # Rust formatting is enforced in-tree via buildRustPackage
  # (see nix/buildRustPackage), which runs cargo fmt --check as part of
  # every crate's checkPhase.  Nix has no equivalent build phase, so we
  # check formatting here as a standalone CI target.
  nixfmt-check =
    runCommand "nixfmt-check"
      {
        nativeBuildInputs = [ nixfmt-rfc-style ];
        src = nixSource;
      }
      ''
        nix_files=$(find "$src" -name '*.nix' -type f -not -path '*/rust/Cargo.nix' | sort)
        if [ -z "$nix_files" ]; then
          touch "$out"
          exit 0
        fi
        nixfmt --check $nix_files
        touch "$out"
      ''
    // {
      __devAttrType = "formatting-check";
    };
}
