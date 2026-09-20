{
  config,
  pkgs,
  lib,
  ...
}:

let
  # pkgs, not config: reading config in imports recurses; the repo doesn't
  # cross-eval, so pkgs' hostPlatform always matches the target machine.
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in
{
  imports = lib.optionals (!isDarwin) [ ./nixos.nix ];

  options.dev.tailscale = {
    enable = lib.mkEnableOption "tailscale daemon";

    authKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file containing a tailscale auth key. When set, a
        tailscale-login oneshot auto-authenticates the node on boot.
      '';
    };
  };

  config = lib.mkIf config.dev.tailscale.enable {
    services.tailscale.enable = true;

    environment.systemPackages = [ pkgs.tailscale ];
  };
}
