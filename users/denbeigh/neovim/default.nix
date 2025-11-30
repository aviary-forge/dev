{ dev, pkgs, ... }:

let
  inherit (pkgs.stdenvNoCC.hostPlatform) system;
  nixvim = dev.third_party.nixvim.legacyPackages.${system};
in
nixvim.makeNixvimWithModule {
  inherit pkgs;
  module = import ./modules;
}
