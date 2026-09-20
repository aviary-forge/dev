{ dev, ... }:

let
  inherit (dev.systems.home-manager.lib) mkConfig;
in
mkConfig {
  # system = "x86_64-linux";
  work = true;

  modules = [
    (
      { ... }:

      {
        imports = [ ../../users/denbeigh/profiles/home-manager.nix ];
        config.dev.denbeigh.machine = {
          username = "discord";
          hostname = "denbeigh";
          work = true;
        };
      }
    )
  ];
}
