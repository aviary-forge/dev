{ dev, ... }:

{
  imports = [
    "${dev.third_party.home-manager.src}/nix-darwin"
    ../common/denbeigh.nix
  ];
  config = {
    home-manager.extraSpecialArgs = { inherit dev; };
  };
}
