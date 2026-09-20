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

  options.dev.denbeigh.tailscale = {
    enable = lib.mkEnableOption "tailscale daemon";
  };

  config = lib.mkIf config.dev.denbeigh.tailscale.enable {
    services.tailscale.enable = true;

    environment.systemPackages = [ pkgs.tailscale ];
  };
}
