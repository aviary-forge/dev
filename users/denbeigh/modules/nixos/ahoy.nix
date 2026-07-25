{ config, lib, ... }:

let
  inherit (lib) mkEnableOption mkIf;

  cfg = config.dev.denbeigh.ahoy;

  groupName = "media";
  serviceConfig = {
    enable = true;
    group = groupName;
  };
in
{
  imports = [
    ./nginx
    ./transmission.nix
  ];

  options.dev.denbeigh.ahoy = {
    enable = mkEnableOption "ahoy";
  };

  config = mkIf cfg.enable {
    users.groups."${groupName}".gid = 94;

    dev.denbeigh = {
      # Be sure we have access to web-facing services
      services.www = {
        enable = true;
        jackett.enable = true;
        jellyfin.enable = true;
        prowlarr.enable = true;
        radarr.enable = true;
        sonarr.enable = true;
        transmission.enable = true;
      };
    };

    services = {
      jellyfin.enable = true;
      # TODO: Create a PR that adds group/package/etc. to this config
      prowlarr.enable = true;
      sonarr = serviceConfig;
      radarr = serviceConfig;
      jackett = serviceConfig;
      transmission = serviceConfig;
    };
  };
}
