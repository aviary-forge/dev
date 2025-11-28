{ members, pkgs, ... }:

pkgs.writeShellApplication {
  name = "codeowners";

  text = "${builtins.readFile ./run.sh}";

  meta.owners = [ members.denbeigh ];

  runtimeInputs = [ pkgs.codeowners ];
}
