{ pkgs, ... }:

pkgs.writeShellApplication {
  name = "post-build-pipeline-step";
  text = builtins.readFile ./run.sh;

  runtimeInputs = [
    pkgs.buildkite-agent
    pkgs.findutils
  ];
}
