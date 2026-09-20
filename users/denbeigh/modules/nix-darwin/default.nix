let
  inherit (builtins) mapAttrs;

  paths = {
    graphical = ./graphical.nix;
    home = ./home.nix;
    system-options = ./system-options.nix;
  };

in
mapAttrs (_: import) paths
