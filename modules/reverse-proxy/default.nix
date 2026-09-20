# NOTE: we add the default for `config` in here because this still ends up
# getting evaluated by readTree during cases of pipeline evaluation and such.
# TODO maybe we take some more reasoned stance with skipTree in future?
{
  config ? { },
  pkgs,
  lib,
  ...
}:

{
  imports = lib.optionals pkgs.stdenv.hostPlatform.isLinux [ ./nixos.nix ];

  options.services.dev.reverse-proxy = {
    enable = lib.mkEnableOption "nginx reverse proxy";

    baseDomain = lib.mkOption {
      type = lib.types.str;
      description = "Base domain name for exposed services.";
    };

    tailscaleAddr = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Tailscale address to bind services to when `tailscale` is enabled
        on a service. Must be set if any service uses `tailscale = true`.
      '';
      example = "100.64.0.1";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open ports 80 and 443 in the firewall.";
    };

    defaultVhost = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            serverName = lib.mkOption {
              type = lib.types.str;
              default = "_";
              description = "server_name for the catch-all vhost.";
            };

            return = lib.mkOption {
              type = lib.types.str;
              default = "444";
              description = "HTTP status code or URL to return for unmatched requests.";
              example = lib.literalExpression ''"444"'';
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

    services = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enable = lib.mkEnableOption "this service in the reverse proxy";

            backend = lib.mkOption {
              type = lib.types.str;
              description = "HTTP backend destination (e.g. `http://localhost:8080`).";
              example = "http://localhost:8080";
            };

            tailscale = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Bind this service to the Tailscale address instead of all
                interfaces. Requires `services.dev.reverse-proxy.tailscaleAddr`
                to be set.
              '';
            };

            ssl = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Enable SSL / ACME for this service.";
            };

            extraConfig = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
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
      enable = lib.mkEnableOption "ACME / LetsEncrypt certificate provisioning via DNS-01 challenge";

      email = lib.mkOption {
        type = lib.types.str;
        description = "Email address for LetsEncrypt registration.";
      };

      dnsProvider = lib.mkOption {
        type = lib.types.str;
        description = ''
          DNS provider name for the ACME DNS-01 challenge. Must be a
          provider supported by lego (e.g. `cloudflare`, `route53`).
        '';
        example = "cloudflare";
      };

      credentialFiles = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = { };
        description = ''
          Credential files for the DNS provider. Keys are environment
          variable names that lego expects (e.g.
          `CF_DNS_API_TOKEN_FILE` for Cloudflare). Values are paths to
          files containing the raw credential.
        '';
        example = lib.literalExpression ''
          {
            "CF_DNS_API_TOKEN_FILE" = config.age.secrets.doToken.path;
          }
        '';
      };

      acceptTerms = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Accept the Let's Encrypt terms of service.";
      };
    };
  };
}
