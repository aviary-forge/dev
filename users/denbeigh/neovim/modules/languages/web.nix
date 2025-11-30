{ pkgs, lib, ... }:

let
  inherit (lib) mkDefault;
in
{
  config = {
    plugins = {
      lsp.servers.ts_ls.enable = mkDefault true;
      rooter.patterns = [
        "package.json"
        "package-lock.json"
        "yarn.lock"
        "pnpm-lock.yaml"
      ];
      treesitter.settings.ensure_installed = [
        "css"
        "html"
        "javascript"
        "tsx"
        "typescript"
      ];
    };

    extraPlugins = with pkgs.vimPlugins; [
      typescript-vim
      vim-javascript
      vim-jsx-typescript
    ];
  };
}
