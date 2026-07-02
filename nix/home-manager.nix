{ dev, pkgs, ... }:

let
  # We'll use this to create the activation script
  activateHomeManager = (
    targetSystem: hmConfig:
    pkgs.writeShellApplication {
      name = "activate-home-manager";
      runtimeInputs = [ dev.third_party.home-manager.cli ];
      text = ''
        # We use the activation script from the built configuration.
        # This is the most direct way to apply the Home Manager generation.
        ${hmConfig.activationPackage}/bin/activate
      '';
    }
  );

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
      # We need to know the target system to select the right pkgs/hm-cli
      # but since we want to be able to build it, we'll use the provided localSystem or default to current
      targetSystem = configuration ? targetSystem || (dev.third_party.nixpkgs.system or "x86_64-linux");
      system = (
        dev.third_party.home-manager.cli.mkHomeManagerConfiguration {
          inherit targetSystem;
          modules = [
            baseModule
            configuration
          ];
          # We inject dev into specialArgs so modules can access it
          specialArgs = { inherit dev; };
        }
      );
    in
    {
      inherit (system) system;
      activate = activateHomeManager targetSystem dev.third_party.home-manager.cli system;
      __devAttrType = "home-manager-system";
    }
  );
}
