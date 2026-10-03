# Vikunja — self-hosted todo/task app, served at <subdomain>.<baseDomain>
# through the shared nginx reverse proxy (modules/reverse-proxy).
#
# Two things here aren't obvious:
#
#  1. service.secret. Vikunja generates a random one per process when it
#     isn't configured, and never persists it — so every restart of aviary
#     would invalidate every session and force a fresh login. We generate
#     it once into a StateDirectory and hand it over as a systemd
#     credential. Not an agenix secret: it authenticates nothing external,
#     so there's nothing to protect it from beyond the local filesystem,
#     and keeping it out of the repo entirely is the point.
#
#  2. The vhost needs proxyWebsockets. Vikunja pushes task updates over a
#     websocket at /api/v1/ws, and the nginx module's proxyWebsockets
#     defaults to false — without it the UI silently stops live-updating.
#
# Database is sqlite: this is a single-user app and aviary runs no database
# server today, so there was no reason to introduce one.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkIf mkOption types;

  cfg = config.dev.denbeigh.services.vikunja;

  backend = "http://localhost:${toString cfg.port}";

  # Must match how nginx actually serves the vhost, or vikunja bakes the
  # wrong origin into the links it hands out and into its CORS checks.
  frontendHostname = "${cfg.subdomain}.${config.services.dev.reverse-proxy.baseDomain}";

  # Root-owned, generated on first boot. Deliberately *not* the vikunja
  # unit's own StateDirectory — that one is remapped to /var/lib/private
  # and chowned to a DynamicUser, which would fight this root-owned write.
  secretDir = "/var/lib/vikunja-secret";
  secretPath = "${secretDir}/service-secret";
in
{
  imports = [ ../../../../modules/reverse-proxy ];

  options.dev.denbeigh.services.vikunja = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Run vikunja and expose it through the reverse proxy.";
    };

    subdomain = mkOption {
      type = types.str;
      default = "vikunja";
      description = "Subdomain to serve vikunja on.";
    };

    port = mkOption {
      type = types.port;
      default = 3456;
      description = "Port the vikunja API listens on.";
    };
  };

  config = mkIf cfg.enable {
    services = {
      vikunja = {
        enable = true;
        inherit (cfg) port;

        frontendScheme = "https";
        inherit frontendHostname;

        database.type = "sqlite";

        settings.service.secret.file = "$CREDENTIALS_DIRECTORY/service-secret";

        # Set directly on the vhost rather than through the reverse proxy's
        # extraConfig: that module builds its vhosts as
        # `svc.extraConfig // { locations."/".proxyPass = ...; ... }`, and `//`
        # is a *shallow* merge, so anything under extraConfig.locations is
        # discarded rather than merged.
      };
      nginx.virtualHosts."${cfg.subdomain}".locations."/".proxyWebsockets = true;
    };

    systemd.services = {
      "vikunja-service-secret" = {
        description = "Generate the vikunja service.secret (JWT signing key)";
        wantedBy = [ "vikunja.service" ];
        before = [ "vikunja.service" ];
        # No-op once the key exists, so it stays stable across rebuilds
        # and reboots. Same shape as reverse-proxy-reject-tls-cert.
        unitConfig.ConditionPathExists = "!${secretPath}";
        serviceConfig = {
          # StateDirectory is a [Service] directive. In unitConfig it lands
          # in [Unit], where systemd ignores it, and the directory never
          # gets created — the script then fails with ENOENT.
          StateDirectory = "vikunja-secret";
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script =
          let
            openssl = lib.getExe pkgs.openssl;
          in
          ''
            umask 0077
            ${openssl} rand -hex 32 > ${secretPath}
          '';
      };

      # Delivered at $CREDENTIALS_DIRECTORY, which vikunja expands when it
      # resolves the .file path above. The credential is what makes this
      # readable at all: vikunja runs as a DynamicUser and can't open the
      # root-owned 0600 file the unit above writes.
      vikunja.serviceConfig.LoadCredential = "service-secret:${secretPath}";
    };

    services.dev.reverse-proxy.services."${cfg.subdomain}" = {
      enable = true;
      inherit backend;
      # Tailscale-bound, like the rest of the personal services. Also worth
      # noting vikunja allows open registration by default.
      tailscale = true;

      # Attachment uploads. nginx's default is 1M; vikunja's own limit
      # (files.maxsize) is 20MB, so without this most uploads fail at the
      # proxy with a 413.
      extraConfig.extraConfig = "client_max_body_size 20M;";
    };
  };
}
