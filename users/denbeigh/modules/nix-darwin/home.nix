{ dev, config, lib, pkgs, ... }:

{
  imports = [
    "${dev.third_party.home_manager.src}/nix-darwin"
    ../common/denbeigh.nix
  ];
  config = {
    home-manager.extraSpecialArgs = { inherit dev; };
  };
}
