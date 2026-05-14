{ pkgs, ... }:

{
  imports = [ ./docker.nix ];

  environment.systemPackages = with pkgs; [
    agenix
    jq
    git
    htop
    vim
    neovim
    ripgrep
    ctags
    file
    unzip
  ];
}
