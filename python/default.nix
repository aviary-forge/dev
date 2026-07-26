{
  dev,
  pkgs,
  lib,
  ...
}@args:

let
  inherit (builtins)
    fromTOML
    readFile
    listToAttrs
    map
    ;

  repoRoot = ../.;

  # --- Initialized third-party libraries ---
  pyproject-nix = dev.third_party."pyproject-nix";
  uv2nix = dev.third_party.uv2nix;
  pyproject-build-systems = dev.third_party."pyproject-build-systems";

  # --- Load workspace ---
  workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = repoRoot; };

  # --- Python package set ---
  pythonSet =
    (pkgs.callPackage pyproject-nix.build.packages {
      python = pkgs.python313;
    }).overrideScope
      (
        lib.composeManyExtensions [
          pyproject-build-systems.overlays.wheel
          (workspace.mkPyprojectOverlay { sourcePreference = "wheel"; })
        ]
      );

  # --- Per-member builder ---
  inherit (import ../nix/buildPythonProject { inherit dev pkgs lib; })
    buildPythonProject
    ;

  # Parse workspace members from root pyproject.toml
  workspaceToml = fromTOML (readFile (repoRoot + "/pyproject.toml"));
  memberPaths = workspaceToml.tool.uv.workspace.members or [ ];

  # Extract package name from a member's pyproject.toml
  memberName =
    memberPath:
    let
      toml = fromTOML (readFile (repoRoot + "/${memberPath}/pyproject.toml"));
    in
    toml.project.name;

  # Build a single workspace member into a clean derivation with static checks
  mkMember =
    memberPath:
    let
      name = memberName memberPath;
    in
    buildPythonProject {
      package = pythonSet.${name};
      venv = pythonSet.mkVirtualEnv "${name}-env" {
        ${name} = workspace.deps.default.${name} or [ ];
      };
      src = repoRoot + "/${memberPath}";
    };

  # Attrset of member-name → derivation
  members = listToAttrs (
    map (mp: {
      name = memberName mp;
      value = mkMember mp;
    }) memberPaths
  );

in
members
// {
  inherit pythonSet workspace;
}
