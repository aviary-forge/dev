{
  config ? { },
  lib,
  ...
}:

let
  inherit (lib)
    filter
    literalExpression
    mapAttrsToList
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    optional
    types
    ;

  cfg = config.services.dev.reverse-proxy;

  # Flatten the services attrset into a list of {name, ...} for easier iteration.
  enabledServices = filter (s: s.enable) (
    mapAttrsToList (name: svc: { inherit name; } // svc) cfg.services
  );
in
{
  options.services.dev.reverse-proxy = {
    enable = mkEnableOption "nginx reverse proxy";

    baseDomain = mkOption {
      type = types.str;
      description = "Base domain name for exposed services.";
    };

    tailscaleAddr = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Tailscale address to bind services to when `tailscale` is enabled
        on a service. Must be set if any service uses `tailscale = true`.
      '';
      example = "100.64.0.1";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open ports 80 and 443 in the firewall.";
    };

    defaultVhost = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            serverName = mkOption {
              type = types.str;
              default = "_";
              description = "server_name for the catch-all vhost.";
            };

            return = mkOption {
              type = types.str;
              default = "444";
              description = "HTTP status code or URL to return for unmatched requests.";
              example = literalExpression ''"444"'';
            };
          };
        }
      );
      default = null;
      description = ''
        Optional default / catch-all virtual host. When set, all requests
        that don't match a configured service will be handled by this
        vhost. A common pattern is `{ serverName = "_"; return = "444"; }`
        to drop unrecognised requests.
      '';
    };

    services = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            enable = mkEnableOption "this service in the reverse proxy";

            backend = mkOption {
              type = types.str;
              description = "HTTP backend destination (e.g. `http://localhost:8080`).";
              example = "http://localhost:8080";
            };

            tailscale = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Bind this service to the Tailscale address instead of all
                interfaces. Requires `services.dev.reverse-proxy.tailscaleAddr`
                to be set.
              '';
            };

            ssl = mkOption {
              type = types.bool;
              default = true;
              description = "Enable SSL / ACME for this service.";
            };

            extraConfig = mkOption {
              type = types.attrsOf types.anything;
              default = { };
              description = ''
                Additional nginx virtual host configuration merged on top of
                the generated config. Merged with `//` (top-level keys from
                extraConfig override generated defaults).
              '';
            };
          };
        }
      );
      default = { };
      description = ''
        Services to expose through the reverse proxy, keyed by subdomain
        name. Each service creates a virtual host at
        `<name>.<baseDomain>`.
      '';
    };

    acme = {
      enable = mkEnableOption "ACME / LetsEncrypt certificate provisioning via DNS-01 challenge";

      email = mkOption {
        type = types.str;
        description = "Email address for LetsEncrypt registration.";
      };

      dnsProvider = mkOption {
        type = types.str;
        description = ''
          DNS provider name for the ACME DNS-01 challenge. Must be a
          provider supported by lego (e.g. `digitalocean`, `cloudflare`,
          `route53`).
        '';
        example = "digitalocean";
      };

      credentialFiles = mkOption {
        type = types.attrsOf types.path;
        default = { };
        description = ''
          Credential files for the DNS provider. Keys are environment
          variable names that lego expects (e.g.
          `DO_AUTH_TOKEN_FILE` for DigitalOcean). Values are paths to
          files containing the raw credential.
        '';
        example = literalExpression ''
          {
            "DO_AUTH_TOKEN_FILE" = config.age.secrets.doToken.path;
          }
        '';
      };

      acceptTerms = mkOption {
        type = types.bool;
        default = true;
        description = "Accept the Let's Encrypt terms of service.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.acme.enable -> (builtins.stringLength cfg.acme.email > 0);
        message = "services.dev.reverse-proxy.acme.email must be set when ACME is enabled.";
      }
      {
        assertion = cfg.acme.enable -> (builtins.stringLength cfg.acme.dnsProvider > 0);
        message = "services.dev.reverse-proxy.acme.dnsProvider must be set when ACME is enabled.";
      }
    ]
    ++ (map (svc: {
      assertion = svc.tailscale -> cfg.tailscaleAddr != null;
      message = ''
        services.dev.reverse-proxy.tailscaleAddr must be set because the
        service "${svc.name}" has tailscale = true.
      '';
    }) enabledServices);

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [
      80
      443
    ];

    security.acme = mkIf cfg.acme.enable {
      inherit (cfg.acme) acceptTerms;
      defaults = {
        inherit (cfg.acme) credentialFiles dnsProvider;
        email = cfg.acme.email;
      };
    };

    services.nginx = {
      enable = true;

      virtualHosts = mkMerge (
        # Optional default / catch-all vhost
        (optional (cfg.defaultVhost != null) {
          "default" = {
            serverName = cfg.defaultVhost.serverName;
            locations."/".return = cfg.defaultVhost.return;
          };
        })
        ++
          # Dynamic per-service vhosts (only enabled ones)
          (map (
            svc:
            let
              addr = if svc.tailscale then cfg.tailscaleAddr else "0.0.0.0";
              enableSSL = svc.ssl;
              fqdn = "${svc.name}.${cfg.baseDomain}";
            in
            {
              ${svc.name} = svc.extraConfig // {
                serverName = fqdn;
                locations."/".proxyPass = svc.backend;

                enableACME = enableSSL;
                forceSSL = enableSSL;
                acmeRoot = mkIf enableSSL null;

                listen = [
                  {
                    inherit addr;
                    port = 80;
                  }
                ]
                ++ optional enableSSL {
                  inherit addr;
                  port = 443;
                  ssl = true;
                };
              };
            }
          ) enabledServices)
      );
    };
  };
}
