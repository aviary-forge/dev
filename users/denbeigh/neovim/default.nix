{ dev, pkgs, members, ... }:

let
  inherit (pkgs.stdenvNoCC.hostPlatform) system;
  nixvim = dev.third_party.nixvim.legacyPackages.${system};
  vim = nixvim.makeNixvimWithModule {
    inherit pkgs;
    module = import ./modules;
  };

  meta = { owners = [ members.denbeigh ]; };
in
vim.overrideAttrs (old: {
  meta = (old.meta or { }) // meta;
})
