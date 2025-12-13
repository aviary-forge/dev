{ lib, ... }:

let
  inherit (lib) mkDefault;
in
{
  config = {
    globals.rust_recommended_style = 0;

    plugins = {
      lsp.servers.rust_analyzer = {
        enable = mkDefault true;
        settings = {
          procMacro.enable = true;
          cargo = {
            allTargets = true;
            features = "all";
            # ensure we do this from the CLI, instead of potentially hanging
            # the editor
            noDeps = true;
          };
          check = {
            command = "clippy";
            features = "all";
          };
        };

        installCargo = false;
        installRustc = false;
      };

      rooter.patterns = [
        "Cargo.toml"
        "Cargo.lock"
      ];
      treesitter.settings.ensure_installed = [ "rust" ];
    };
  };
}
