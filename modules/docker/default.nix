{
  pkgs,
  lib,
  ...
}:

{
  imports = lib.optionals pkgs.stdenv.hostPlatform.isLinux [ ./nixos.nix ];

  options.dev.docker.enable = lib.mkEnableOption "docker + docker tooling";
}
