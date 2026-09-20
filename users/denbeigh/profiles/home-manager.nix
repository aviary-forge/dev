{
  dev,
  config,
  pkgs,
  lib,
  ...
}:

let
  inherit (lib) mkOption types;
  inherit (config.dev.denbeigh.machine) username;
  inherit (pkgs.stdenvNoCC.hostPlatform) isDarwin;
in
{
  imports = [
    ../modules/home-manager/dev.nix
    ../modules/home-manager/git.nix
    ../modules/home-manager/htop.nix
    ../modules/home-manager/zsh
    ../modules/home-manager/graphical.nix
    ../modules/home-manager/pi.nix
    ../modules/home-manager/scripts.nix
    ../modules/home-manager/use-nix-cache.nix
    ../modules/home-manager/webcam.nix
  ];

  options.dev.denbeigh = {
    machine = {
      username = mkOption {
        type = types.str;
        default = "denbeigh";
        description = ''
          Username of the user to provision on the system.
        '';
      };

      hostname = mkOption {
        type = types.str;
        description = ''
          The hostname of the machine being provisioned.
        '';
      };

      graphical = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether this machine will be used interactively.
        '';
      };

      # TODO: Make naming consistent
      isNixOS = mkOption {
        type = types.bool;
        description = ''
          Whether the machine being provisioned is running NixOS.
        '';
      };

      work = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether this machine will be used for "work" purposes.
        '';
      };
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
      default = [ "id_ed25519" ];
      description = ''
        The SSH key paths to expect to use.
      '';
    };

    inherit (dev.users.denbeigh.utils.locations.options) location;

  };

  config = {
    # Default pi extension set; machines may override or extend.
    programs.pi-coding-agent.myPackages = with dev.third_party.pi-extensions; [
      context-mode
      pi-intercom
      pi-mcp-adapter
      pi-prompt-template-model
      pi-subagents
      plannotator
      rpiv-ask-user-question
      rpiv-todo
    ];

    home = {
      inherit username;
      homeDirectory = lib.mkDefault (if isDarwin then "/Users/${username}" else "/home/${username}");

      packages = with pkgs; [ ripgrep ];

      # This value determines the Home Manager release that your
      # configuration is compatible with. This helps avoid breakage
      # when a new Home Manager release introduces backwards
      # incompatible changes.
      #
      # You can update Home Manager without changing this value. See
      # the Home Manager release notes for a list of state version
      # changes in each release.
      stateVersion = "22.05";
    };

    programs = {
      # Let Home Manager install and manage itself.
      home-manager.enable = true;

      aria2.enable = true;
      fzf.enable = true;
      gh.enable = true;
      jq.enable = !config.dev.denbeigh.machine.work;
      tmux.enable = true;

      keychain = {
        enable = (builtins.length config.dev.denbeigh.keys) > 0;
        inherit (config.dev.denbeigh) keys;
      };
    };
  };
}
