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
    ../../../../systems/modules/nixos/reverse-proxy
    ./transmission.nix
  ];

  options.dev.denbeigh.ahoy = {
    enable = mkEnableOption "ahoy";
  };

  config = mkIf cfg.enable {
    users.groups."${groupName}".gid = 94;

    dev.denbeigh = {
      # Use the custom transmission wrapper (handles transmission_4, settings, etc.)
      services.transmission = {
        enable = true;
        group = groupName;
      };
    };

    services.dev.reverse-proxy.services = {
      jackett = {
        enable = true;
        backend = "http://localhost:9117";
        tailscale = true;
      };

      jellyfin = {
        enable = true;
        backend = "http://localhost:8096";
        tailscale = true;
        extraConfig = {
          locations = {
            "= /web/".proxyPass = "http://localhost:8096/web/index.html";
            "= /".return = "302 http://$host/web/";

            " = socket".proxyWebsockets = true;

            "/" = {
              proxyPass = "http://localhost:8096";
              extraConfig = ''
                client_max_body_size 20M;
                proxy_buffering off;

                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_set_header X-Forwarded-Protocol $scheme;
                proxy_set_header X-Forwarded-Host $http_host;
              '';
            };
          };
        };
      };

      prowlarr = {
        enable = true;
        backend = "http://localhost:9696";
        tailscale = true;
      };

      radarr = {
        enable = true;
        backend = "http://localhost:7878";
        tailscale = true;
      };

      sonarr = {
        enable = true;
        backend = "http://localhost:8989";
        tailscale = true;
      };

      transmission = {
        enable = true;
        backend = "http://localhost:9091";
        tailscale = true;
      };
    };

    services = {
      jellyfin.enable = true;
      # TODO: Create a PR that adds group/package/etc. to this config
      prowlarr.enable = true;
      sonarr = serviceConfig;
      radarr = serviceConfig;
      jackett = serviceConfig;
    };
  };
}
