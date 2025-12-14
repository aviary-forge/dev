{ dev, pkgs, ... }:

let
  activateSystem = (system:
    pkgs.writeShellApplication {
      name = "activate-system";

      text = ''
        ${system}/sw/bin/darwin-rebuild switch
      '';
    });

in
rec {
  baseModule = { ... }: {
    nixpkgs.pkgs = dev.third_party.nixpkgs;

    # allow us to skip the global configuration check, similar to building with
    # flakes
    system.checks.verifyNixPath = false;
  };

  eval = configuration:
    let
      config = (dev.third_party.darwin.eval {
        configuration = { ... }: {
          imports = [ baseModule configuration ];
        };

      });
    in
    {
      inherit (config) system;
      activate = (activateSystem config.system);
    };

  activate = activateSystem;
}
