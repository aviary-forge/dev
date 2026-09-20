{ pkgs, dev, ... }:

{
  environment.systemPackages = with pkgs; [
    dev.third_party.agenix.cli
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
