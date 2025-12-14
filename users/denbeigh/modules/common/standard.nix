{ config, lib, pkgs, ... }:

{
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];

    # Remote-build key from personal machines
    trusted-public-keys = [ "remote-build:gmaC+UE4JxbR6wcMtuZ6WZF0nL1Jh2D3REY9zdwZFWg=" ];
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
}
