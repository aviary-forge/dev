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
    attrNames
    ;

  repoRoot = ../.;

  # --- Import pinned niv sources ---
  uv2nixSrc = dev.third_party.nix.uv2nix;
  pyprojectNixSrc = dev.third_party.nix."pyproject-nix";
  buildSystemPkgsSrc = dev.third_party.nix."pyproject-build-systems";

  # --- Import nix libraries ---
  pyproject-nix = import pyprojectNixSrc { inherit lib; };
  uv2nix = import uv2nixSrc { inherit lib pyproject-nix; };
  pyproject-build-systems = import buildSystemPkgsSrc { inherit lib uv2nix pyproject-nix; };

  # --- Load workspace ---
  workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = repoRoot; };

  # --- Python package set ---
  python = pkgs.python313;

  pythonSet =
    (pkgs.callPackage pyproject-nix.build.packages {
      inherit python;
    }).overrideScope
      (
        lib.composeManyExtensions [
          pyproject-build-systems.overlays.wheel
          (workspace.mkPyprojectOverlay { sourcePreference = "wheel"; })
        ]
      );

  # --- Per-member builder ---
  inherit (import ../nix/buildPythonProject { inherit pkgs lib pyproject-nix; })
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
      venv = pythonSet.mkVirtualEnv "${name}-env" workspace.deps.default;
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
  __readTreeChildrenOverride = members;

  # Expose the full python set and workspace for downstream consumers
  inherit pythonSet workspace;
}
