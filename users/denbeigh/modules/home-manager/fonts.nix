{ dev, pkgs, ... }:

let
  src = dev.third_party.nix.fonts;
  fonts = pkgs.callPackage src { };
  # TODO: Using overlays in standalone HM configs?
  inherit (fonts) sf-mono sf-pro;
in
{
  nixpkgs.overlays = [ "${src}/overlay.nix" ];
  home.packages = [
    sf-mono
    sf-pro
    pkgs.powerline-fonts
  ];
}
