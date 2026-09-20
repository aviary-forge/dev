{
  config,
  lib,
  pkgs,
  ...
}:

{
  config = lib.mkIf config.dev.denbeigh.docker.enable {
    environment.systemPackages = with pkgs; [
      docker
      docker-compose
    ];

    virtualisation.docker.enable = true;
  };
}
