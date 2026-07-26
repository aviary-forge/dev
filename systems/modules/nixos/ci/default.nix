# NOTE: we add the default for `config` in here because this still ends up
# getting evaluated by readTree during cases of pipeline evaluation and such.
# TODO maybe we take some more reasoned stance with skipTree in future?
{
  config ? { },
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
in
{
  imports = [
    ./cache.nix
  ];

  options.services.dev.ci =
    let
      inherit (lib)
        mkEnableOption
        mkPackageOption
        mkOption
        types
        ;
    in
    {
      enable = mkEnableOption "CI agent for aviary forge";

      package = mkPackageOption pkgs "buildkite-agent" { };

      privateSshKeyPath = mkOption {
        type = types.str;
        description = "Path to SSH key to use for authentication";
      };

      tokenPath = mkOption {
        type = types.str;
        description = "Path to file containing Buildkite agent token";
      };

      agentCount = mkOption {
        type = types.int;
        description = "Number of CI workers to run";
        default = 4;
      };

      # TODO: can/do we need to we make this more flexible?"
      groupName = mkOption {
        type = types.str;
        description = "Group name to create for CI agents";
        default = "ci-agents";
      };

      defaultBranch = mkOption {
        type = types.str;
        default = "trunk";
        description = ''
          Name of the default branch (e.g. "trunk", "main").
          Injected as CI_DEFAULT_BRANCH into Buildkite agent jobs
          so the orchestrator can detect trunk builds for caching,
          gcroot management, and Discord notifications.
        '';
      };
    };

  config =
    let
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
      users.groups."${cfg.groupName}" = { };

      systemd.tmpfiles.rules = [
        "d /nix/var/nix/gcroots/dev 0775 root ${cfg.groupName}"
      ];

      services.buildkite-agents = mkIf cfg.enable (listToAttrs (map mkAgent (range 0 count)));

      # If the cache module is enabled, default the cache group to the
      # CI agent group so machine configs don't need to set it twice.
      services.dev.ci.cache.group = lib.mkDefault cfg.groupName;
    };
}
