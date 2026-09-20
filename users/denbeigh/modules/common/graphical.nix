{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (lib)
    mkIf
    mkOption
    elem
    filter
    types
    ;
  cfg = config.dev.denbeigh.machine;
in
{
  imports = [ ./variables.nix ];

  options.dev.denbeigh.machine.graphical = mkOption {
    type = types.bool;
    default = false;
    description = ''
      Whether this machine will be used interactively.
    '';
  };

  # Persona packages to drop from the graphical base set (work.nix
  # excludes personal apps on work machines).
  options.dev.denbeigh.graphical.excludePackages = mkOption {
    type = types.listOf types.package;
    default = [ ];
  };

  config = mkIf cfg.graphical {
    # NOTE: Not compatible with home-manager
    # (nixos and darwin only)
    environment.systemPackages =
      let
        base = with pkgs; [
          (if pkgs.stdenv.hostPlatform.isDarwin then ghostty-bin else ghostty)
          mpv
          yubikey-manager
          discord-canary
          firefox-bin
        ];
      in
      filter (p: !elem p config.dev.denbeigh.graphical.excludePackages) base;
  };
}
