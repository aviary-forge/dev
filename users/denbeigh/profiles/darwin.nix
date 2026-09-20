{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.dev.denbeigh;

  inherit (lib) mkDefault;
in
{
  imports = [
    ../modules/nix-darwin/graphical.nix
    ../modules/nix-darwin/home.nix
    ../modules/nix-darwin/system-options.nix
    ../../../modules/all.nix
    ../../../modules/common/standard.nix
    ../modules/common/variables.nix
    ../modules/common/work.nix
  ];

  config = {
    dev = {
      tailscale.enable = mkDefault true;
      nix-cache.enable = mkDefault (!config.dev.nix-cache-serve.enable);
    };

    networking.hostName = cfg.machine.hostname;

    # pip3, clang, etc are often called from various tooling, and cause the
    # xcode licence agreement popup
    environment.systemPackages = [
      (pkgs.python3.withPackages (
        ps: with ps; [
          pip
          setuptools
          wheel
          virtualenv
        ]
      ))
      pkgs.stdenv.cc
    ];

    users = {
      knownUsers = [ cfg.user.username ];
      users.${cfg.user.username} = {
        name = cfg.user.username;
        home = "/Users/${cfg.user.username}";

        uid = 501;
        shell = cfg.user.shell;
      };
    };
  };
}
