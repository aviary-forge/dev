{ dev, members, ... }:

dev.nix.nixos.eval {
  configuration =
    { pkgs, ... }:
    {
      imports = [
        (pkgs.path + "/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix")
      ];

      config = {
        services.openssh.enable = true;
      };
    };

  meta.owners = with members; [ denbeigh ];
}
