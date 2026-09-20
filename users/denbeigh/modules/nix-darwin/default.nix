let
  inherit (builtins) mapAttrs;

  paths = {
    standard = ./standard.nix;

    graphical = ./graphical.nix;
    home = ./home.nix;
    system-options = ./system-options.nix;
    upload-daemon = ./upload-daemon.nix;
  };

in
mapAttrs (_: import) paths
