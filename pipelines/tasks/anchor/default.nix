{ dev, pkgs, ... }:

pkgs.writeShellApplication {
  name = "anchor-pipeline-step";
  text = builtins.readFile ./run.sh;

  runtimeInputs = [
    pkgs.nix
    dev.gcroot-manager
  ];
}
