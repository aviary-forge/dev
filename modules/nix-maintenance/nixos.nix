{ config, lib, ... }:

{
  config = lib.mkIf config.dev.denbeigh.nix-maintenance.enable {
    nix.gc = {
      dates = "weekly";
      randomizedDelaySec = "45min";
    };

    nix.optimise = {
      dates = "weekly";
      randomizedDelaySec = "30min";
    };
  };
}
