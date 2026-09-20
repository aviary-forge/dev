# Client-side config for the personal nix cache. Subtly different from
# dev.denbeigh.services.nix-cache (the serve-side module, NixOS-only).
{
  config,
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
      type = types.nullOr types.str;
      default = null;
      description = ''
        URL of the nix cache. Required when enable is set; supplied by
        the persona layer.
      '';
    };

    publicKey = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Public key of the nix cache for trusting purposes. Required when
        enable is set; supplied by the persona layer.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.url != null && cfg.publicKey != null;
        message = ''
          dev.denbeigh.nix-cache: url and publicKey must be set when the
          client-side cache is enabled.
        '';
      }
    ];

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
