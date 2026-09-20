# Thin re-export of the devshell defined in default.nix.
#
# Exists as a sibling of default.nix so readTree imports it as the
# `shell` child of //infra/terraform, making the shell a first-class
# CI target (stamped mkShell wrapper -> drvmap -> realisation).
#
# Also the entry point for direnv (`use nix` in .envrc), so it must
# work standalone without readTree args — hence the defaults below.
{
  dev ? import ../.. { },
  pkgs ? dev.third_party.nixpkgs,
  members ? import ../../members.nix,
  ...
}:
(import ./default.nix {
  inherit dev pkgs members;
}).devShell
