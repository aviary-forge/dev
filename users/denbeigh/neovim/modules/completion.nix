{ lib, ... }:

let
  inherit (lib) mkDefault;
in
{
  config.plugins = {
    luasnip.enable = true;
    cmp = {
      enable = mkDefault true;
      settings = {
        completion.keyword_length = 0;
        snippet.expand = "function(args) require('luasnip').lsp_expand(args.body) end";
        preselect = "cmp.PreselectMode.None";
        sources = [
          { name = "luasnip"; }
          { name = "buffer"; }
          { name = "path"; }
        ];

        mapping = {
          "<CR>" = "cmp.mapping.confirm({ select = true })";
          "<C-n>" = ''
            cmp.mapping({
              c = function()
                if cmp.visible() then
                  cmp.select_next_item({ behavior = cmp.SelectBehavior.Select })
                else
                  vim.api.nvim_feedkeys(t("<Down>"), "n", true)
                end
              end,
              i = function(fallback)
                if cmp.visible() then
                  cmp.select_next_item({ behavior = cmp.SelectBehavior.Select })
                else
                  fallback()
                end
              end,
            })
          '';

          "<C-p>" = ''
            cmp.mapping({
              c = function()
                if cmp.visible() then
                  cmp.select_prev_item({ behavior = cmp.SelectBehavior.Select })
                else
                  vim.api.nvim_feedkeys(t("<Up>"), "n", true)
                end
              end,
              i = function(fallback)
                if cmp.visible() then
                  cmp.select_prev_item({ behavior = cmp.SelectBehavior.Select })
                else
                  fallback()
                end
              end,
            })
          '';
        };
      };
    };
  };
}
