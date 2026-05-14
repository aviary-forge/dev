{ dev, ... }:

dev.nix.nixos.eval (
  { pkgs, ... }:
  {
    imports = [
      (pkgs.path + "/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix")
    ];

    config = {
      services.openssh.enable = true;
    };
  }
)
