{ dev, pkgs, ... }:

{
  mkConfig =
    {
      # system,
      work ? false,
      modules ? [ ],
      extraSpecialArgs ? { },
    }:
    let
      # pkgs = import dev.third_party.nixpkgs {
      #   inherit system;
      #   overlays = [
      #     # dev.third_party.nixgl.overlays.default
      #   ];
      # };

      # Ensure we avoid conflicting with any work-provided packages
      priority = if work then 10 else 5;

      inherit (pkgs.lib) setPrio;
      inherit (dev.third_party.home-manager.cli.lib) homeManagerConfiguration;

      config = homeManagerConfiguration {
        inherit pkgs;
        modules = [ { dev.denbeigh.machine.isNixOS = false; } ] ++ modules;
        extraSpecialArgs = {
          inherit dev;
        }
        // extraSpecialArgs;
      };
    in
    setPrio priority config;
}
