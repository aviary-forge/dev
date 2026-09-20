{
  config,
  lib,
  ...
}:

let
  inherit (lib)
    mkIf
    mkMerge
    optional
    ;
  inherit (lib.lists) map;

  cfg = config.services.dev.reverse-proxy;

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
