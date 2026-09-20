{
  pkgs,
  lib,
  ...
}:

{
  imports = lib.optionals pkgs.stdenv.hostPlatform.isLinux [ ./nixos.nix ];

  options.dev.denbeigh.services.nix-cache = {
    enable = lib.mkEnableOption "External Nix cache";

    keyFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Key file to authenticate requests from cache.
      '';
    };
  };
}
