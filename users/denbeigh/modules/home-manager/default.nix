let
  inherit (builtins) mapAttrs;

  paths = {
    dev = ./dev.nix;
    git = ./git.nix;
    htop = ./htop.nix;
    zsh = ./zsh;
    linux = ./linux.nix;
    graphical = ./graphical.nix;
    pi = ./pi.nix;
    scripts = ./scripts.nix;
    standard = ./standard.nix;
    webcam = ./webcam.nix;
  };
in
mapAttrs (_: import) paths
