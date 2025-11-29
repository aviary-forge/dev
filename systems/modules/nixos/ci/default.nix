{ config, pkgs, lib, ... }:

let
  inherit (builtins) toString;
  cfg = config.services.dev.ci;

  mkAgent = n: {
    name = "aviary-worker-${toString n}";
    value = {
      inherit (cfg) enable package tokenPath privateSshKeyPath;
      extraGroups = [ cfg.groupName ];
    };
  };
in
{
  options.services.dev.ci =
    let
      inherit (lib) mkEnableOption mkPackageOption mkOption types;
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
    };

  config =
    let
      inherit (builtins) listToAttrs map;
      inherit (lib.lists) range;
      inherit (lib.modules) mkIf;

      count =
        if cfg.agentCount < 1
        then throw "agent count must be > 0, found ${toString cfg.agentCount}"
        else cfg.agentCount - 1;
    in
    {
      users.groups."${cfg.groupName}" = { };

      services.buildkite-agents = mkIf cfg.enable
        (listToAttrs (map mkAgent (range 0 count)));
    };
}
