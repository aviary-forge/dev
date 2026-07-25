{
  dev,
  config,
  lib,
  ...
}:

let
  inherit (builtins) listToAttrs map;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    recursiveUpdate
    types
    ;

  cfg = config.dev.denbeigh.services.www;
in
{

  imports = [
    ./jackett.nix
    ./jellyfin.nix
    ./nix-cache.nix
    ./prowlarr.nix
    ./radarr.nix
    ./sonarr.nix
    ./transmission.nix
  ];

  options.dev.denbeigh.services.www = {
    enable = mkEnableOption "Web server";

    baseDomain = mkOption {
      type = types.str;
      default = "denbeigh.cloud";
      description = ''
        Base domain name to use for exposed services
      '';
    };

    services = mkOption {
      description = ''
        Services to expose through web server.
      '';
      default = [ ];
      type = types.listOf (
        types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              description = ''
                Name of the service to expose (used in domain name).
              '';
            };

            backend = mkOption {
              type = types.str;
              description = ''
                HTTP destination of the backend to serve.
              '';
            };

            tailscale = mkEnableOption "tailscale proxy serving";

            tailscaleIP = mkOption {
              # NOTE: This defaults aviary's tailscale IP
              # TODO: Use interface name instead somehow?
              default = "100.71.134.67";
              type = types.str;
              description = ''
                Tailscale IP to serve tailscale services on.
              '';
            };

            ssl = mkOption {
              default = true;
              type = types.bool;
              description = ''
                Whether to enable SSL serving.
              '';
            };

            extraConfig = mkOption {
              default = { };
              type = types.attrs;
              description = ''
                Additional config to pass to the nginx virtual host verbatim.
              '';
            };
          };
        }
      );
    };
  };

  config = mkIf cfg.enable {
    age.secrets.digitalOceanKey.file = dev.secrets."digitalOceanAPIKey.age";

    security.acme = {
      acceptTerms = true;
      defaults = {
        credentialFiles = {
          # Lego reads this env var and expects the file to contain the raw
          # API token (not KEY=value format as the old credentialsFile did).
          "DO_AUTH_TOKEN_FILE" = config.age.secrets.digitalOceanKey.path;
        };
        dnsProvider = "digitalocean";
        email = "denbeigh+letsencrypt@denbeighstevens.com";
      };
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];

    services.nginx = {
      enable = true;
      # Drop all inbound connections by default
      virtualHosts = {
        "misc" = {
          serverName = "_";
          locations."/".return = "444";
        };
      }
      // (
        # Build our dynamic list of hosts from configuration
        let
          buildService =
            service:
            let
              addr = (if service.tailscale then service.tailscaleIP else "0.0.0.0");

              enableSSL = service.ssl || service.tailscale;
            in
            {
              inherit (service) name;
              # value = config // ssl // tailscale;
              value = (
                recursiveUpdate service.extraConfig {
                  serverName = "${service.name}.${cfg.baseDomain}";
                  locations."/".proxyPass = service.backend;

                  enableACME = enableSSL;
                  forceSSL = enableSSL;
                  # Must be null to enforce using DNS challenge default
                  acmeRoot = mkIf enableSSL null;

                  listen = [
                    {
                      inherit addr;
                      port = 80;
                    }
                  ]
                  ++ (
                    if enableSSL then
                      [
                        {
                          inherit addr;
                          port = 443;
                          ssl = true;
                        }
                      ]
                    else
                      [ ]
                  );
                }
              );
            };

          # buildService = s: builtins.trace (buildService' s).value (buildService' s);
        in
        listToAttrs (map buildService cfg.services)
      );
    };
  };
}
