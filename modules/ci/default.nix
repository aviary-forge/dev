# NOTE: we add the default for `config` in here because this still ends up
# getting evaluated by readTree during cases of pipeline evaluation and such.
# TODO maybe we take some more reasoned stance with skipTree in future?
{
  config ? { },
  pkgs,
  lib,
  ...
}:

{
  imports = lib.optionals pkgs.stdenv.hostPlatform.isLinux [ ./nixos.nix ];

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
    };
}
