{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkIf
    mkMerge
    optional
    optionalAttrs
    ;
  inherit (lib.lists) map;

  cfg = config.services.dev.reverse-proxy;

  # Throwaway self-signed pair for the TLS catch-all vhost; never used to
  # serve traffic (ssl_reject_handshake drops the handshake first).
  throwawayCert =
    pkgs.runCommand "reverse-proxy-reject-tls-snakeoil" { nativeBuildInputs = [ pkgs.openssl ]; }
      ''
        mkdir $out
        openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
          -subj "/CN=reject-tls.placeholder" \
          -keyout $out/key.pem -out $out/fullchain.pem
      '';

  # Flatten the services attrset into a list of {name, ...} for easier iteration.
  enabledServices = lib.filter (s: s.enable) (
    lib.mapAttrsToList (name: svc: { inherit name; } // svc) cfg.services
  );
in
{
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
    ++ (lib.map (svc: {
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
          }
          // optionalAttrs cfg.defaultVhost.rejectTls {
            # Unknown-SNI TLS to a public IP would otherwise fall through
            # to a real service vhost; reject it during the handshake
            # (nginx's ssl_reject_handshake, via NixOS's `rejectSSL`).
            # The :80 listener is explicit so this block stays the
            # default_server for *:80 (it previously got that implicitly).
            listen = [
              {
                addr = "0.0.0.0";
                port = 80;
                extraParameters = [ "default_server" ];
              }
              {
                addr = "0.0.0.0";
                port = 443;
                ssl = true;
                extraParameters = [ "default_server" ];
              }
            ];
            rejectSSL = true;
            # The handshake is always rejected, but the nginx module
            # still emits ssl_certificate lines for any ssl listener, so
            # hand it a throwaway self-signed pair it can parse.
            sslCertificate = "${throwawayCert}/fullchain.pem";
            sslCertificateKey = "${throwawayCert}/key.pem";
          };
        })
        ++
          # Dynamic per-service vhosts (only enabled ones)
          (lib.map (
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
