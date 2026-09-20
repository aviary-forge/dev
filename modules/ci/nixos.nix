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
      # Drvmap cache shared by ci-orchestrator pipeline-gen across agents.
      # Setgid so files inherit the group; the binary writes entries mode
      # 0664 (group-writable). Never cleaned up by tmpfiles (age "-");
      # entries are keyed by commit SHA and validated against the drvmap.nix
      # entry point on load, so stale entries are harmless.
      "d /var/cache/ci-orchestrator/drvmap-cache 2775 root ${cfg.groupName} - -"
    ];

    services.buildkite-agents = listToAttrs (map mkAgent (range 0 count));
  };
}
