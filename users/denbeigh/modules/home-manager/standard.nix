{ dev
, config
, pkgs
, lib
, ...
}:


let
  inherit (lib) mkOption types;
  inherit (config.dev.denbeigh) username;
  inherit (pkgs.stdenvNoCC.hostPlatform) isDarwin;
in
{
  imports = [
    ./dev.nix
    ./git.nix
    ./htop.nix
    ./zsh
    ./graphical.nix
    ./scripts.nix
    ./use-nix-cache.nix
    ./webcam.nix
  ];

  options.dev.denbeigh = {
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

    graphical = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether this machine will be used interactively.
      '';
    };

    inherit (dev.users.denbeigh.utils.locations.options) location;

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

  config = {
    # Home Manager needs a bit of information about you and the
    # paths it should manage.
    home = {
      inherit username;
      homeDirectory = if isDarwin then "/Users/${username}" else "/home/${username}";

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
      jq.enable = !config.dev.denbeigh.work;
      tmux.enable = true;

      keychain = {
        enable = (builtins.length config.dev.denbeigh.keys) > 0;
        inherit (config.dev.denbeigh) keys;
      };
    };
  };
}

