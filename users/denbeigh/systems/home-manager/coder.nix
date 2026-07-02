{ dev, ... }:

let
  inherit (dev.users.denbeigh.systems.home-manager.lib) mkConfig;
in
mkConfig {
  # system = "x86_64-linux";
  work = true;

  modules = [
    (
      { ... }:

      {
        imports = [ ../../modules/home-manager/standard.nix ];
        config.dev.denbeigh.machine = {
          username = "discord";
          hostname = "denbeigh";
          work = true;
        };
      }
    )
  ];
}
