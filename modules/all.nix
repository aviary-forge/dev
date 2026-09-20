# Auto-import of feature modules.
#
# Contract: a module here must be inert unless its enable option is set,
# and platform-specific config must live in <feature>/nixos.nix (or
# darwin.nix), imported only on that platform, so foreign eval contexts
# never see undeclared options. modules/common is excluded: always-on
# base that depends on persona options.
#
# Plain attrset, no function args: module arguments are evaluated during
# the module fixpoint and cause infinite recursion here. readTree skips this
# directory entirely (.skip-subtree): these are modules imported by path,
# not readTree targets, and readTree requires every .nix file it sees to be
# a callable lambda.
{
  imports =
    let
      # Always-on base (depends on persona options), imported explicitly
      # by the profiles instead.
      excluded = [ "common" ];

      entries = builtins.readDir ./.;
      isFeature =
        name:
        !(builtins.elem name excluded)
        && entries.${name} == "directory"
        && builtins.pathExists (./. + "/${name}/default.nix");
    in
    map (name: ./. + "/${name}") (builtins.filter isFeature (builtins.attrNames entries));
}
