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
    # ../../../modules/darwin/use-nix-cache.nix (stub, disabled)
    ../modules/nix-darwin/home.nix
    ../modules/nix-darwin/system-options.nix
    # ../modules/nix-darwin/upload-daemon.nix
    ../../../modules/common/standard.nix
    ../modules/common/variables.nix
    ../../../modules/tailscale
  ];

  config = {
    dev.denbeigh.tailscale.enable = mkDefault true;

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
