{ lib, pkgs, ... }:

let
  inherit (lib) mkDefault;
in
{

  config = {
    plugins = {
      lsp.servers.elp = {
        enable = mkDefault true;
        cmd = [
          "${pkgs.erlang-language-platform}/bin/elp"
          "server"
        ];
      };

      treesitter.settings.ensure_installed = [ "erlang" ];
      rooter.patterns = [
        "rebar.config"
        "rebar.lock"
      ];
    };

    extraPackages = with pkgs; [
      beam28Packages.erlang
      stdenv.cc
    ];
  };
}
