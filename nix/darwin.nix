{ dev, pkgs, ... }:

let
  activateSystem = (system:
    pkgs.writeShellApplication {
      name = "activate-system";

      runtimeInputs = [ dev.third_party.darwin.darwin-rebuild ];

      text = ''
        darwin-rebuild activate ${system}
      '';
    });

in
rec {
  baseModule = { ... }: {
    nixpkgs.pkgs = dev.third_party.nixpkgs;
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
