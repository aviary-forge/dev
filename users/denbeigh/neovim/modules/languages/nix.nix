{ pkgs, lib, ... }:

let
  inherit (lib) mkDefault;
in
{
  config = {
    plugins = {
      nix.enable = mkDefault true;
      lsp.servers.nixd = {
        enable = mkDefault true;
        settings.formatting.command = [ "${pkgs.nixfmt-rfc-style}/bin/nixfmt" ];
      };

      rooter.patterns = [ "flake.nix" ];
      treesitter.settings.ensure_installed = [ "nix" ];
    };
  };
}
