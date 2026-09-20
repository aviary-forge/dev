{ dev, ... }:

let
  inherit (dev.systems.home-manager.lib) mkConfig;
  pins = import ../../users/denbeigh/modules/common/cache-pins.nix;
in
mkConfig {
  # system = "x86_64-linux";
  work = true;

  modules = [
    (
      {
        lib,
        pkgs,
        ...
      }:

      {
        imports = [
          ../../users/denbeigh/profiles/home-manager.nix
          ../../modules/use-nix-cache
        ];
        config = {
          dev.denbeigh.machine = {
            username = "discord";
            hostname = "denbeigh";
            work = true;
          };

          dev.nix-cache = {
            enable = true;
            inherit (pins) url publicKey;
          };

          # HM generates this machine's nix.conf, which requires a nix
          # package to generate against.
          nix.package = lib.mkDefault pkgs.nix;
        };
      }
    )
  ];
}
