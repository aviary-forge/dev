{
  dev,
  config,
  lib,
  pkgs,
  ...
}:

{
  options =
    let
      inherit (lib) mkOption types;

      cfg = config.dev.denbeigh.dev;
    in
    {
      dev.denbeigh.dev = {
        enable = mkOption {
          description = "Whether to manage the default set of build tools";
          type = types.bool;
          default = !config.dev.denbeigh.work;
        };
        languages = {
          go.enable = mkOption {
            description = "Install Golang build tools";
            type = types.bool;
            default = cfg.enable;
          };

          rust.enable = mkOption {
            description = "Install Rust build tools";
            type = types.bool;
            default = cfg.enable;
          };

          node.enable = mkOption {
            description = "Install NodeJS build tools";
            type = types.bool;
            default = cfg.enable;
          };

          python.enable = mkOption {
            description = "Install Python build tools";
            type = types.bool;
            default = cfg.enable;
          };
        };
      };
    };

  config =
    let
      cfg = config.dev.denbeigh.dev.languages;

      inherit (pkgs)
        python313
        go
        nodejs
        nodePackages
        ;
      inherit (pkgs.lib) optionals;

      rust-pkgs = optionals cfg.rust.enable [ pkgs.fenix.stable.toolchain ];
      go-pkgs = optionals cfg.go.enable [ go ];
      node-pkgs = optionals cfg.node.enable [
        nodejs
        nodePackages.yarn
        nodePackages.pnpm
      ];
      python-pkgs = optionals cfg.python.enable [ python313 ];
    in
    {
      home.packages =
        with pkgs;
        [
          dev.third_party.agenix.cli
          dev.users.denbeigh.neovim
          ctags
          direnv
        ]
        ++ rust-pkgs
        ++ go-pkgs
        ++ node-pkgs
        ++ python-pkgs;
    };
}
