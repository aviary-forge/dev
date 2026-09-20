# Auto-import of feature modules.
#
# Contract: a module here must be inert unless its enable option is set,
# and platform-specific config must live in <feature>/nixos.nix (or
# darwin.nix), imported only on that platform, so foreign eval contexts
# never see undeclared options. modules/common is excluded: always-on
# base that depends on persona options.
{
  excluded ? [ "common" ],
  lib,
  ...
}:

let
  featureDirs = lib.filterAttrs (
    name: type:
    type == "directory"
    && builtins.pathExists (./. + "/${name}/default.nix")
    && !builtins.elem name excluded
  ) (builtins.readDir ./.);
in
{
  imports = map (name: ./. + "/${name}") (builtins.attrNames featureDirs);
}
