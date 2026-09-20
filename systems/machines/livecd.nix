{ dev, members, ... }:

dev.nix.nixos.eval {
  # Platform declared as data: reading .system on the target must not force
  # the module fixpoint (CI drvmap filters foreign systems without eval).
  system = "x86_64-linux";

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
