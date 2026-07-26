{ dev, pkgs, ... }:

pkgs.writeShellApplication {
  name = "build-step";
  text = builtins.readFile ./run.sh;

  runtimeInputs = [
    pkgs.buildkite-agent
    dev.pipelines.tasks.ci-orchestrator
  ];
}
