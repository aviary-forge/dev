{
  pkgs,
  lib,
  ...
}:

{
  imports = lib.optionals pkgs.stdenv.hostPlatform.isLinux [ ./nixos.nix ];

  options.dev.ssh = {
    enable = lib.mkEnableOption "ssh to the machine";

    sshPort = lib.mkOption {
      type = lib.types.number;
      default = 22;
      description = ''
        Port to serve SSH on (if enabled).
      '';
    };
  };
}
