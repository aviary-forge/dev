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
      # Ensure we avoid conflicting with any work-provided packages
      priority = if work then 10 else 5;

      inherit (pkgs.lib) setPrio;
      inherit (dev.third_party.home-manager.cli.lib) homeManagerConfiguration;

      config = homeManagerConfiguration {
        inherit pkgs;
        modules = [
          {
            targets.genericLinux.enable = pkgs.lib.mkDefault pkgs.stdenv.hostPlatform.isLinux;
          }
        ]
        ++ modules;
        extraSpecialArgs = {
          inherit dev;
        }
        // extraSpecialArgs;
      };
    in
    setPrio priority config;
}
