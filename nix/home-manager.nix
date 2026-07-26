{ dev, pkgs, ... }:

let
  # We'll use this to create the activation script
  activateHomeManager =
    targetSystem: hmConfig:
    pkgs.writeShellApplication {
      name = "activate";
      runtimeInputs = [ dev.third_party.home-manager.cli ];
      text = ''
        # We use the activation script from the built configuration.
        # This is the most direct way to apply the Home Manager generation.
        ${hmConfig.activationPackage}/bin/activate
      '';
    };

  baseModule = _: {
    nixpkgs.pkgs = dev.third_party.nixpkgs;
  };

in
{
  inherit baseModule;

  # eval: produce a home-manager system target.
  #
  # Accepts either a configuration function directly (legacy) or an
  # attrset with `configuration` and optional `meta` (preferred).
  # `meta.owners` is threaded through to the drvmap for CI ownership.
  eval =
    arg:
    let
      configuration = if builtins.isFunction arg then arg else arg.configuration;
      meta = if builtins.isFunction arg then { } else arg.meta or { };

      # We need to know the target system to select the right pkgs/hm-cli
      # but since we want to be able to build it, we'll use the provided localSystem or default to current
      targetSystem = configuration ? targetSystem || (dev.third_party.nixpkgs.system or "x86_64-linux");
      hmConfig = dev.third_party.home-manager.cli.mkHomeManagerConfiguration {
        inherit targetSystem;
        modules = [
          baseModule
          configuration
        ];
        # We inject dev into specialArgs so modules can access it
        specialArgs = { inherit dev; };
      };
    in
    {
      inherit (hmConfig) system;
      inherit (hmConfig.activationPackage) outPath drvPath;
      inherit meta;
      activate = activateHomeManager targetSystem dev.third_party.home-manager.cli hmConfig;
      __devAttrType = "home-manager-system";
    };
}
