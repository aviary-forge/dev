# NOTE: Subtly different from dev.nix-cache (the client-side
# module, in use-nix-cache).
{
  config,
  lib,
  ...
}:

let
  cfg = config.dev.nix-cache-serve;
in
{
  imports = [ ../reverse-proxy ];

  config = lib.mkIf cfg.enable {
    users.users.nix-copy-receiver = {
      # Needed to grant any access over SSH at all
      isNormalUser = true;
      group = "nix-copy-receiver";
      openssh.authorizedKeys.keys = cfg.receiverAuthorizedKeys;
    };
    users.groups.nix-copy-receiver = { };

    services = {
      dev.reverse-proxy.services.nix-cache = {
        enable = true;
        backend = "http://localhost:5000";
        # Public (off tailscale): harmonia is an unauthenticated, read-only
        # binary cache, integrity is enforced client-side by serve-key
        # signatures, and narinfo hashes are unguessable — see
        # docs/public-nix-cache-exposure.md for the threat model.
        tailscale = false;

        # Abuse controls: cap concurrent connections per client IP and rate
        # limit requests. Numbers are deliberately generous (nix opens ~8-16
        # parallel connections; narinfo traffic is tiny-but-bursty) — tune
        # against real build behaviour after rollout.
        extraConfig.extraConfig = ''
          limit_conn nixcache_conn 16;
          limit_req zone=nixcache_req burst=40 nodelay;
        '';
      };

      # limit zones must be declared once in the http context; this is the
      # only consumer of the `nixcache_*` zones.
      nginx.commonHttpConfig = ''
        limit_conn_zone $binary_remote_addr zone=nixcache_conn:10m;
        limit_req_zone  $binary_remote_addr zone=nixcache_req:10m rate=100r/s;
      '';

      harmonia.cache = {
        enable = true;
        signKeyPaths = [ cfg.keyFile ];
        settings = {
          # Nix cache priority
          priority = 50;
          # Concurrent workers
          workers = 4;
          # Max. open connections
          max_connection_rate = 256;
        };
      };
    };
  };
}
