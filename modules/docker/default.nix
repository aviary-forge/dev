{
  pkgs,
  lib,
  ...
}:

{
  imports = lib.optionals pkgs.stdenv.hostPlatform.isLinux [ ./nixos.nix ];

  options.dev.denbeigh.docker.enable = lib.mkEnableOption "docker + docker tooling";
}
