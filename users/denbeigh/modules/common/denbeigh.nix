{ config, lib, pkgs, ... }:

let
  inherit (lib) mkIf mkOption types;
  cfg = config.dev.denbeigh;
in
{
  options.dev.denbeigh = {
    user = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Install extended user dotfiles.
        '';
      };

      username = mkOption {
        type = types.str;
        default = "denbeigh";
        description = ''
          Username of the user to provision on the system.
        '';
      };

      shell = mkOption {
        type = types.package;
        default = pkgs.zsh;
        description = ''
          Shell to use for the environment.
        '';
      };

      # TODO: Rename this?
      keys = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          The SSH key paths to expect to use.
        '';
      };
    };

    machine.isNixOS = mkOption {
      type = types.bool;
      default = false;
      description = ''
        If this machine is running NixOS.
      '';
    };
  };

  config = {
    home-manager = mkIf cfg.user.enable {
      useGlobalPkgs = true;
      useUserPackages = true;

      users.${cfg.user.username} = {
        imports = [ ../home-manager/standard.nix ];

        dev.denbeigh = {
          inherit (cfg.machine) graphical hostname work isNixOS;
          inherit (cfg.user) username keys;
        };
      };
    };
  };
}
