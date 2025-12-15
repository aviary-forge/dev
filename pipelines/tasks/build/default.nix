# This file configures the primary build pipeline used for the
# top-level list of targets.
{
  dev,
  pkgs ? dev.third_party.nixpkgs,
  externalArgs ? { },
  gcrootCommitCount ? 5,
  ...
}:

let
  pipeline = dev.nix.buildkite.mkPipeline {
    headBranch = "trunk";
    drvTargets = dev.ci.targets;

    parentTargetMap =
      if (externalArgs ? parentTargetMap) then
        builtins.fromJSON (builtins.readFile externalArgs.parentTargetMap)
      else
        { };

    postBuildSteps = [
      # After successful builds, create a gcroot for the derivations at the
      # HEAD of trunk, and trim all but the last ${gcrootCommitCount}.
      #
      # This anchors *most* of the repo, in practice it's unimportant
      # if there is a build race and we get +-1 of the targets.
      #
      # Unfortunately this requires a third evaluation of the graph.
      #
      # TODO: devise a better approach where we can keep a couple of recent
      # refs around (and maybe introduce some ref management of our own)
      {
        label = ":construction_worker:";
        branches = "trunk";
        command = ''
          $(nix-build -A pipelines.tasks.anchor)/bin/anchor-pipeline-step
        '';
        env = {
          GCROOT_GCROOT_DIR = "/nix/var/nix/gcroots/dev/trunk";
          GCROOT_COMMITS_TO_KEEP = builtins.toString gcrootCommitCount;
        };
      }
    ];
  };

  drvmap = dev.nix.buildkite.mkDrvmap dev.ci.targets;
in
pkgs.runCommand "build-pipeline-step" { } ''
  mkdir $out
  cp -r ${pipeline}/* $out
  cp ${drvmap} $out/drvmap.json
''
