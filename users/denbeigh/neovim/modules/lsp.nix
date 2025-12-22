{ lib, ... }:

let
  inherit (lib) mkDefault;
in
{
  config = {
    opts.signcolumn = "yes";

    diagnostic = {
      settings = {
        virtual_lines = true;
      };
    };
    plugins = {
      lsp-format.enable = mkDefault true;
      lsp = {
        enable = mkDefault true;
        # TODO: switch to new default neovim bindings (usually gr_) see :help
        # lsp-defaults
        keymaps = {
          diagnostic = {
            "<leader>k" = "goto_prev";
            "<leader>j" = "goto_next";
          };

          lspBuf = {
            # ctrl-s
            # K = "signature_help";
            # (K is now hover!)

            # grr
            "<leader>R" = "references";
            # grn
            "<leader>r" = "rename";
            "<leader>f" = "format";
            # grt
            "<leader><leader>" = "definition";
            # gra
            "<leader>z" = "code_action";

            # also... gri -> implementation
          };
        };
      };

      cmp-nvim-lsp.enable = mkDefault true;
      cmp.settings.sources = [
        {
          name = "nvim_lsp";
        }
      ];
    };
  };
}
