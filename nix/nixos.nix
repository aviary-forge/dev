{ dev, pkgs, ... }:

let
  # NOTE: this currently requires us to copy the monorepo to the store, but the
  # cost is still low enough that i'm not too fussed about that.
  activateSystem =
    system:
    pkgs.writeShellApplication {
      name = "activate";

      text = ''
        if [[ "$EUID" -ne "0" ]]
        then
          echo "system must be activated as root" >&2
          exit 1
        fi

        nix-env -p /nix/var/nix/profiles/system --set ${system}
        ${system}/bin/switch-to-configuration switch
      '';
    };

  baseModule =
    { ... }:
    {
      nixpkgs.pkgs = dev.third_party.nixpkgs;
    };

in

{
  inherit baseModule;

  # eval: produce a NixOS system target.
  #
  # Accepts either a configuration function directly (legacy) or an
  # attrset with `configuration` and optional `meta` (preferred).
  # `meta.owners` is threaded through to the drvmap for CI ownership.
  eval = (
    arg:
    let
      configuration =
        if builtins.isFunction arg then arg else arg.configuration;
      meta = if builtins.isFunction arg then { } else arg.meta or { };

      nixosEval = (
        dev.third_party.nixos {
          configuration =
            { ... }:
            {
              imports = [
                baseModule
                configuration
              ];
            };

          specialArgs = {
            inherit dev pkgs;
          };
        }
      );

    in
    {
      inherit (nixosEval) vm;
      system = nixosEval.system.system;
      inherit (nixosEval.system) outPath drvPath;
      inherit meta;
      activate = activateSystem nixosEval.system;
      __devAttrType = "nixos-system";
    }
  );
}
