{ config, lib, ... }:

let
  inherit (lib) mkDefault;
in
{
  # Ensures the serve-side options are defined (but disabled by default)
  imports = [ ../nix-cache ];

  config.dev.denbeigh.nix-cache.enable = mkDefault (!config.dev.denbeigh.services.nix-cache.enable);
}
