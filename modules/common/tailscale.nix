{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkEnableOption mkIf;

  cfg = config.dev.denbeigh.tailscale;
in
{
  options.dev.denbeigh.tailscale = {
    enable = mkEnableOption "tailscale daemon";
  };

  config = mkIf cfg.enable {
    services.tailscale.enable = true;

    environment.systemPackages = [ pkgs.tailscale ];
  };
}
