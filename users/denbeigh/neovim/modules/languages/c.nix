{ lib, ... }:

let
  inherit (lib) mkDefault;
in

{
  config = {
    plugins = {
      lsp.servers.clangd.enable = mkDefault true;
      treesitter.settings.ensure_installed = [
        "c"
        "cpp"
      ];
    };
  };
}
