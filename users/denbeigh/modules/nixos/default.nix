let
  inherit (builtins) mapAttrs;

  paths = {
    ahoy = ./ahoy.nix;
    aws = ./cloud/aws;
    aws-aarch64 = ./cloud/aws/aarch64.nix;
    bullshit = ./bullshit.nix;
    cloud = ./cloud;
    denbeigh = ./denbeigh.nix;
    development = ./development.nix;
    gaming = ./gaming.nix;
    terraform = ./terraform.nix;
    update-fonts = ./update-fonts.nix;
  };
in
mapAttrs (_: import) paths
