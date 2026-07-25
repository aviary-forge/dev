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
    ./graphical.nix
    # ./use-nix-cache.nix
    ./home.nix
    ./system-options.nix
    # ./upload-daemon.nix
    ../common/standard.nix
    ../common/variables.nix
    ../common/tailscale.nix
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
      };
    };
  };
}
