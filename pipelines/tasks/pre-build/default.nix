{ dev, pkgs, ... }:

pkgs.writeShellApplication {
  name = "pre-build-pipeline-step";
  text = builtins.readFile ./run.sh;

  runtimeInputs = [
    pkgs.buildkite-agent
    pkgs.nix
    pkgs.findutils

    dev.pipelines.tasks.fetch-parent-targets
  ];
}
