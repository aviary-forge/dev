{
  config,
  options,
  pkgs,
  lib,
  ...
}:

let
  inherit (lib)
    mkIf
    mkMerge
    mkDefault
    mkForce
    hasAttrByPath
    optionalAttrs
    ;

  # this should be flexible enough to run safely in home-manager configs, as
  # well as linux and darwin systems.
  #
  # NOTE: two different gates, and neither works for both purposes:
  #   - option-existence must be checked via `options` with
  #     optionalAttrs — the module system's undeclared-option check
  #     walks definition paths structurally, so an mkIf-wrapped
  #     definition still errors even when its condition is false.
  #   - the work condition must be an mkIf — optionalAttrs' condition
  #     is strict, and forcing `config` while building the config
  #     attrset recurses into the fixpoint.
  has = path: hasAttrByPath path options;

  work = config.dev.denbeigh.machine.work;
in
{
  config = mkMerge [
    # home-manager: company git identity (git.nix carries the personal
    # default; work machines override it here)
    (optionalAttrs
      (has [
        "programs"
        "git"
        "settings"
      ])
      {
        programs.git.settings.user.email = mkIf work (mkForce "denbeigh.stevens@discordapp.com");
      }
    )

    # home-manager: no jq, no personal build toolchains on work machines
    (optionalAttrs
      (has [
        "programs"
        "jq"
      ])
      {
        programs.jq.enable = mkIf work (mkForce false);
      }
    )
    (optionalAttrs
      (has [
        "dev"
        "denbeigh"
        "dev"
      ])
      {
        dev.denbeigh.dev.enable = mkIf work (mkDefault false);
      }
    )

    # use unpinned canary and updateable firefox at the office
    (optionalAttrs
      (has [
        "dev"
        "denbeigh"
        "graphical"
        "excludePackages"
      ])
      {
        dev.denbeigh.graphical.excludePackages = mkIf work (
          with pkgs;
          [
            discord-canary
            firefox-bin
          ]
        );
      }
    )

    # darwin: disable yabai ESA option to keep SIP
    (optionalAttrs
      (has [
        "services"
        "yabai"
      ])
      {
        services.yabai.enableScriptingAddition = mkIf work (mkForce false);
      }
    )
  ];
}
