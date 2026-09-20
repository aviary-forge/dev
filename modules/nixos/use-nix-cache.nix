{ config, lib, ... }:

let
  inherit (lib)
    mkDefault
    ;

in
{
  # Ensures services.nix-cache options are defined
  # (but they're disabled by default)
  imports = [
    ./nix-cache.nix
    ../common/use-nix-cache.nix
  ];

  config.dev.denbeigh.nix-cache.enable = mkDefault (!config.dev.denbeigh.services.nix-cache.enable);
}
