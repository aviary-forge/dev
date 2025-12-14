{ dev, pkgs, ... }:

let
  activateSystem = (
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
        ${system}/sw/bin/darwin-rebuild activate
      '';
    }
  );

in
rec {
  baseModule =
    { ... }:
    {
      nixpkgs.pkgs = dev.third_party.nixpkgs;

      # allow us to skip the global configuration check, similar to building with
      # flakes
      system.checks.verifyNixPath = false;
    };

  eval =
    configuration:
    let
      config = (
        dev.third_party.darwin.eval {
          configuration =
            { ... }:
            {
              imports = [
                baseModule
                configuration
              ];
            };

        }
      );
    in
    config.system
    // {
      activate = (activateSystem config.system);
    };
}
