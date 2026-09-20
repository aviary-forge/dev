# Client-side config for the personal nix cache. Subtly different from
# dev.nix-cache-serve (the serve-side module, NixOS-only).
{
  config,
  lib,
  ...
}:

let
  inherit (lib) mkIf mkOption types;

  cfg = config.dev.nix-cache;
in
{

  options.dev.nix-cache = {
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
          dev.nix-cache: url and publicKey must be set when the
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
