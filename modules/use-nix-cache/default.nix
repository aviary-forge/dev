# Client-side config for the personal nix cache. Subtly different from
# dev.denbeigh.services.nix-cache (the serve-side module, NixOS-only).
{
  pkgs,
  lib,
  ...
}:

let
  inherit (lib) mkIf mkOption types;

  cfg = config.dev.denbeigh.nix-cache;

  # pkgs, not config: reading config in imports recurses; the repo doesn't
  # cross-eval, so pkgs' hostPlatform always matches the target machine.
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in
{
  imports = lib.optionals (!isDarwin) [ ./nixos.nix ];

  options.dev.denbeigh.nix-cache = {
    enable = mkOption {
      type = types.bool;
      # On NixOS, ./nixos.nix defaults this to the inverse of the
      # serve-side toggle.
      default = false;
      description = ''
        Whether to enable personal nix cache.
      '';
    };

    url = mkOption {
      type = types.str;
      default = "https://nix-cache.denbeigh.cloud";
      description = ''
        URL of our nix cache.
      '';
    };

    publicKey = mkOption {
      type = types.str;
      default = "nix-cache.denbeigh.cloud-1:UeYPpNKlT8gTl7jRqOb+hawFbI5B20pPfSUbpWvSe9U=";
      description = ''
        Public key of our nix cache for trusting purposes.
      '';
    };
  };

  config = mkIf cfg.enable {
    nix.settings = {
      # Sometimes we may not be connected to Tailscale.
      connect-timeout = 3;
      # For some reason, we don't make use of our own resolver by default if we
      # only make use of extra-substituters here
      # (cache.nixos.org is added to substituters and trusted-substituters by default)
      extra-substituters = [ cfg.url ];
      extra-trusted-substituters = [ cfg.url ];
      extra-trusted-public-keys = [ cfg.publicKey ];
    };
  };
}
