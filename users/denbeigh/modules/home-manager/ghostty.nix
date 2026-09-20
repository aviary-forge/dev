{
  config,
  pkgs,
  lib,
  ...
}:

let
  inherit (lib)
    mkDefault
    mkIf
    optional
    mkOption
    types
    ;
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  inherit (config.dev.denbeigh.ghostty)
    enable
    enableTerminfo
    shouldGlWrap
    fontSize
    fontFamily
    ;
  tools = pkgs.callPackage ./lib { };
  # pkgs.ghostty is linux-only in nixpkgs; on darwin the official app bundle
  # repack (ghostty-bin) is the blessed path.
  ghosttyPackage = if isDarwin then pkgs.ghostty-bin else pkgs.ghostty;
  package = if shouldGlWrap then (tools.glWrap ghosttyPackage "ghostty") else ghosttyPackage;
in
{
  options.dev.denbeigh.ghostty = {
    enable = mkOption {
      type = types.bool;
      default = config.dev.denbeigh.machine.graphical;
      description = ''
        Whether to install and manage Ghostty.
      '';
    };

    enableTerminfo = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to install terminfo for Ghostty.
      '';
    };

    shouldGlWrap = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to wrap Ghostty in NixGL. Defaulted from
        targets.genericLinux.enable in config.
      '';
    };

    fontSize = mkOption {
      type = types.float;
      default = 10.0;
      description = ''
        Font size to use in terminal.
      '';
    };

    fontFamily = mkOption {
      type = types.str;
      default = "Roboto Mono for Powerline";
      description = ''
        Font to use in terminal.
      '';
    };
  };

  config = {
    dev.denbeigh.ghostty.shouldGlWrap = mkDefault config.targets.genericLinux.enable;

    # install terminfo if requested and we aren't installing the package itself
    home.packages = optional (!enable && enableTerminfo) package.terminfo;
    programs.ghostty = mkIf enable {
      enable = true;
      inherit package;
      settings = {
        # Colors (Gruvbox dark, soft contrast background)
        theme = "Gruvbox Dark";
        # Ghostty's GruvboxDark uses hard-contrast (0x282828); preserve the
        # soft-contrast background we had under alacritty.
        # NOTE: bare hex — ghostty's config parser treats `#` after
        # whitespace as the start of a comment.
        background = "32302f";

        font-family = fontFamily;
        font-size = fontSize;
      };
    };
  };
}
