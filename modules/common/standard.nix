{
  config,
  lib,
  pkgs,
  ...
}:

{
  options.dev.remoteBuildPublicKeys = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = ''
      Public keys of personal remote-build caches to trust.
    '';
  };

  config = {
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];

      # Remote-build keys to trust; supplied by the persona layer.
      trusted-public-keys = config.dev.remoteBuildPublicKeys;
      trusted-users = [ config.dev.denbeigh.user.username ];
    };

    time.timeZone = config.dev.denbeigh.machine.location.timezone;

    programs.zsh = {
      enable = true;
      promptInit = "";
    };

    environment.systemPackages = with pkgs; [
      git
      nix
    ];
  };
}
