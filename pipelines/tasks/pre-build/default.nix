{ dev, pkgs, ... }:

pkgs.writeShellApplication {
  name = "pre-build-pipeline-step";
  text = builtins.readFile ./run.sh;

  runtimeInputs = [
    pkgs.buildkite-agent
    pkgs.nix
    pkgs.git

    dev.pipelines.tasks.ci-orchestrator
  ];
}
