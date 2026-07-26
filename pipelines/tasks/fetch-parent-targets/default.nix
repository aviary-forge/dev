{ pkgs, ... }:

pkgs.writeShellApplication {
  name = "fetch-parent-targets";
  text = builtins.readFile ./run.sh;

  runtimeInputs = [
    pkgs.git
    pkgs.curl
    pkgs.jq
  ];
}
