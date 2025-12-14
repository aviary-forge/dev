{ dev, pkgs, ... }:

rec {
  baseModule = { ... }: {
    nixpkgs.pkgs = dev.third_party.nixpkgs;
  };

  eval = configuration:
    (dev.third_party.nixos
      {
        configuration = { ... }: {
          imports = [
            baseModule
            configuration
          ];
        };

        specialArgs = {
          inherit dev;
        };
      });

  # NOTE: this currently requires us to copy the monorepo to the store, but the
  # cost is still low enough that i'm not too fussed about that.
  activate = configuration:
    pkgs.writeShellApplication {
      name = "activate-system";

      text = ''
        if [[ "$EUID" -ne "0" ]]
        then
          echo "system must be activated as root" >&2
          exit 1
        fi

        nix-env -p /nix/var/nix/profiles/system --set ${configuration}
        ${configuration}/bin/switch-to-configuration switch
      '';
    };
}
