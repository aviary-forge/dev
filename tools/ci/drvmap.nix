# Nix expression that produces a drvmap JSON object when instantiated with
# `nix eval --json -f tools/ci/drvmap.nix drvmap`.
#
# This is the interface between Nix (discovery) and Rust (orchestration).
# The Rust binary runs this in a worktree to get the drvmap for a given commit.
{
  dev ? import ../.. { },
  ...
}:

let
  inherit (builtins) listToAttrs map unsafeDiscardStringContext;

  inherit (dev.nix.readTree) mkLabel;
  inherit (dev.nix.buildkite) targetAttrPath;
  inherit (dev.nix.dependency-analyzer) drvsToPaths;

  # All CI targets
  targets = dev.ci.targets;

  # Build a drvPath -> treePath reverse lookup
  drvToTreePath =
    let
      pairs = map (t: {
        drv = unsafeDiscardStringContext t.drvPath;
        tree = mkLabel t;
      }) targets;
    in
    builtins.listToAttrs (map (p: { name = p.drv; value = p.tree; }) pairs);

  # Compute the forward dependency graph and resolve drvPaths to treePaths
  depMap = dev.nix.dependency-analyzer (drvsToPaths targets);

  # For a given target, return the list of treePaths it depends on
  getDeps = target:
    let
      drv = unsafeDiscardStringContext target.drvPath;
      knownDeps = depMap.${drv}.knownDeps or [ ];
    in
    map (d: drvToTreePath.${d} or d) knownDeps;

  toDrvmapEntry = target: {
    name = mkLabel target;
    value = {
      drvPath = unsafeDiscardStringContext target.drvPath;
      attrPath = targetAttrPath target;
      system = target.system or dev.third_party.nixpkgs.system;
      outputs =
        if target ? outputs then
          builtins.listToAttrs (map (o: { name = o; value = target.${o}.outPath; }) target.outputs)
        else
          { };
      owners = target.meta.owners or [ ];
      deps = getDeps target;
    };
  };
in
{
  drvmap = listToAttrs (map toDrvmapEntry targets);
}
