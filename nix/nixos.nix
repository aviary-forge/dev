{ dev, pkgs, ... }:

let
  # NOTE: this currently requires us to copy the monorepo to the store, but the
  # cost is still low enough that i'm not too fussed about that.
  activateSystem =
    system:
    pkgs.writeShellApplication {
      name = "activate-system";

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
  eval = (
    configuration:
    let
      system = (
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
            inherit dev;
          };
        }
      );

    in
    {
      inherit (system) system vm;
      activate = activateSystem system.system;
      __devAttrType = "nixos-system";
    }
  );
}
