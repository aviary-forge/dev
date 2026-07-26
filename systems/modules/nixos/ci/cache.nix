# NixOS module: creates the drvmap merge-base cache directory and
# injects CI_DRVMAP_CACHE_DIR / CI_DEFAULT_BRANCH into each Buildkite
# agent so the ci-orchestrator binary can find them.
#
# The directory is created with setgid (2775) so that cache files
# written by different agents (running under different users but the
# same group) remain readable and writable by the group.
#
# Optionally runs periodic cache cleanup via a systemd timer.
#
# Usage:
#   services.dev.ci.cache = {
#     enable = true;
#     group = "ci-agents";
#     package = dev.rust.ci;  # ci-orchestrator binary
#     # dir defaults to /var/cache/ci-orchestrator/drvmap-cache
#   };
{
  config,
  lib,
  ...
}:

let
  ciCfg = config.services.dev.ci;
  cfg = config.services.dev.ci.cache;
in
{
  options.services.dev.ci.cache = {
    enable = lib.mkEnableOption "drvmap merge-base cache for CI orchestrator";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The ci-orchestrator package (e.g. dev.rust.ci).";
    };

    dir = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/ci-orchestrator/drvmap-cache";
      description = ''
        Path to the merge-base drvmap cache directory.
        The ci-orchestrator binary reads CI_DRVMAP_CACHE_DIR from the
        environment, falling back to this default.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      description = "Unix group that owns the cache directory.";
    };

    clean = {
      enable = lib.mkEnableOption "periodic cache cleanup" // {
        default = true;
      };

      retain = lib.mkOption {
        type = lib.types.int;
        default = 50;
        description = "Number of recent cache entries to keep.";
      };

      schedule = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = "systemd OnCalendar schedule for cleanup.";
        example = "Sat *-*-* 03:00:00";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Create the cache directory with setgid so cache files inherit the
    # group.  Mode 2775 = setgid + rwxrwxr-x.  The orchestrator binary
    # creates individual cache files with mode 0664.
    systemd.tmpfiles.rules = [
      "d ${cfg.dir} 2775 root ${cfg.group} -"
    ];

    # Inject CI_DRVMAP_CACHE_DIR and CI_DEFAULT_BRANCH into every
    # enabled buildkite agent service so the env vars are inherited
    # by all job processes (pipeline-gen, build, post-build).
    systemd.services = lib.mkMerge (
      [
        (lib.mkIf cfg.clean.enable {
          # One-shot service to clean old cache entries.
          ci-cache-clean = {
            description = "Clean old merge-base drvmap cache entries";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${cfg.package}/bin/ci-orchestrator cache-clean --retain ${toString cfg.clean.retain}";
              User = "root";
              Group = cfg.group;
            };
          };
        })
      ]
      ++ (lib.mapAttrsToList (name: _agentCfg: {
        "buildkite-agent-${name}".environment = {
          CI_DRVMAP_CACHE_DIR = cfg.dir;
          CI_DEFAULT_BRANCH = ciCfg.defaultBranch;
        };
      }) (lib.filterAttrs (_: a: a.enable) config.services.buildkite-agents))
    );

    # Timer to trigger periodic cleanup.
    systemd.timers = lib.mkIf cfg.clean.enable {
      ci-cache-clean = {
        description = "Periodic drvmap cache cleanup";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.clean.schedule;
          Persistent = true;
        };
      };
    };
  };
}
