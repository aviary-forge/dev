# NixOS module: creates the drvmap merge-base cache directory and
# injects CI_DRVMAP_CACHE_DIR into each Buildkite agent so the
# ci-orchestrator binary can find it.
#
# The directory is created with setgid (2775) so that cache files
# written by different agents (running under different users but the
# same group) remain readable and writable by the group.
#
# Usage:
#   services.dev.ci.cache = {
#     enable = true;
#     group = "ci-agents";
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
      lib.mapAttrsToList (name: _agentCfg: {
        "buildkite-agent-${name}".environment = {
          CI_DRVMAP_CACHE_DIR = cfg.dir;
          CI_DEFAULT_BRANCH = ciCfg.defaultBranch;
        };
      }) (lib.filterAttrs (_: a: a.enable) config.services.buildkite-agents)
    );
  };
}
