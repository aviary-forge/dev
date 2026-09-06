# pi-coding-agent home-manager module (plan: docs/pi-packaging-plan.md).
#
# The agent binary goes on PATH, and declared extensions/skills are merged
# into ~/.pi/agent/settings.json at activation time. The settings file is
# mutable state that pi rewrites at runtime (lastChangelogVersion,
# defaultProvider, ...), so we never manage it wholesale: the merge script
# (dev.nix.mkPiPackage.mergeSettings) surgically updates only the `packages`
# and `skills` keys, dropping the ad-hoc "npm:..." entries superseded by nix
# packages and appending the store-path local packages.
{
  config,
  lib,
  pkgs,
  dev,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.programs.pi-coding-agent;

  packagesJson = builtins.toJSON (map (p: p.piPackageDir) cfg.myPackages);
  # The ad-hoc "npm:..." settings entries each nix package supersedes.
  removeJson = builtins.toJSON (map (p: p.npmSourceString) cfg.myPackages);
  skillsJson = builtins.toJSON cfg.skills;
in
{
  options.programs.pi-coding-agent = {
    enable = mkEnableOption "pi coding agent";

    package = mkOption {
      type = types.package;
      default = dev.third_party.pi-extensions.pi-coding-agent-host;
      defaultText = "dev.third_party.pi-extensions.pi-coding-agent-host";
      description = ''
        The pi-coding-agent package to install. Defaults to the host wrapper
        (third_party/pi-extensions/pi-coding-agent-host) which provides the
        peer packages pi-subagents' async runner needs for background
        children; the plain nixpkgs build cannot run background children.
      '';
    };

    myPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = ''
        pi extension packages (mkPiPackage derivations exposing a
        piPackageDir passthru). Each piPackageDir is registered as a
        local-path package in ~/.pi/agent/settings.json.
      '';
    };

    skills = mkOption {
      type = types.listOf types.str;
      default = [ "${config.home.homeDirectory}/dev/chess-agent-skills/.agents/skills" ];
      description = ''
        Skill directory paths, replacing the settings.json `skills` key
        wholesale at activation. Empty to leave skills untouched.
      '';
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];

    home.activation.piMergeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      SETTINGS_FILE="${config.home.homeDirectory}/.pi/agent/settings.json" \
      PACKAGES_JSON=${lib.escapeShellArg packagesJson} \
      REMOVE_JSON=${lib.escapeShellArg removeJson} \
      SKILLS_JSON=${lib.escapeShellArg skillsJson} \
        ${dev.nix.mkPiPackage.mergeSettings}
    '';
  };
}
