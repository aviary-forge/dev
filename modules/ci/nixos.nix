{
  config,
  pkgs,
  lib,
  ...
}:

let
  inherit (builtins) toString;
  cfg = config.services.dev.ci;

  mkAgent = n: {
    name = "aviary-worker-${toString n}";
    value = {
      inherit (cfg)
        enable
        package
        tokenPath
        privateSshKeyPath
        ;
      extraGroups = [ cfg.groupName ];

      tags = {
        arch = pkgs.stdenvNoCC.hostPlatform.parsed.cpu.name;
        os = pkgs.stdenvNoCC.hostPlatform.parsed.kernel.name;
        hostname = config.networking.hostName;
        # Convenience: maps to "true" on the default queue
        queue = "default";
      };

      runtimePackages = [
        # included by default
        pkgs.bash
        pkgs.gnutar
        pkgs.gzip
        pkgs.git
        pkgs.nix

        # added by us (so we can run the initial pipeline generation step)
        pkgs.buildkite-agent
      ];
    };
  };

  inherit (builtins) listToAttrs map;
  inherit (lib.lists) range;
  inherit (lib.modules) mkIf;

  count =
    if cfg.agentCount < 1 then
      throw "agent count must be > 0, found ${toString cfg.agentCount}"
    else
      cfg.agentCount - 1;
in
{
  config = mkIf cfg.enable {
    users.groups."${cfg.groupName}" = { };

    systemd.tmpfiles.rules = [
      "d /nix/var/nix/gcroots/dev 0775 root ${cfg.groupName}"
    ];

    services.buildkite-agents = listToAttrs (map mkAgent (range 0 count));
  };
}
