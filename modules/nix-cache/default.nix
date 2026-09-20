{
  pkgs,
  lib,
  ...
}:

{
  imports = lib.optionals pkgs.stdenv.hostPlatform.isLinux [ ./nixos.nix ];

  options.dev.nix-cache-serve = {
    enable = lib.mkEnableOption "External Nix cache";

    keyFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Key file to authenticate requests from cache.
      '';
    };

    receiverAuthorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        SSH keys permitted to upload to the cache (the nix-copy-receiver
        user).
      '';
    };
  };
}
