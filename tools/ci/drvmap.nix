# Nix expression that produces a drvmap JSON object when instantiated with
# `nix-instantiate --json -A drvmap`.
#
# This is the interface between Nix (discovery) and Rust (orchestration).
# The Rust binary runs `nix-instantiate --json -A drvmap tools/ci/drvmap.nix`
# in a worktree to get the drvmap for a given commit.
{
  dev ? import ../.. { },
}:

let
  inherit (builtins) listToAttrs map unsafeDiscardStringContext;

  inherit (dev.nix.readTree) mkLabel;
  inherit (dev.nix.buildkite) targetAttrPath;

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
    };
  };
in
{
  drvmap = listToAttrs (map toDrvmapEntry dev.ci.targets);
}
