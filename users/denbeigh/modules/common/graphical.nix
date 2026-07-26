{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.dev.denbeigh.machine;
in
{
  options.dev.denbeigh.machine.graphical = mkOption {
    type = types.bool;
    default = false;
    description = ''
      Whether this machine will be used interactively.
    '';
  };

  config = mkIf cfg.graphical {
    # NOTE: Not compatible with home-manager
    # (nixos and darwin only)
    environment.systemPackages = with pkgs; [
      alacritty
      discord-canary
      mpv
      yubikey-manager
      # Maybe some other time
      # https://github.com/NixOS/nixpkgs/issues/71689
      # firefox
    ];
  };
}
