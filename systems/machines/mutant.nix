{ dev, members, ... }:

dev.nix.darwin.eval {
  # Platform declared as data: reading .system on the target must not force
  # the module fixpoint (CI drvmap filters foreign systems without eval).
  system = "aarch64-darwin";

  configuration =
    { pkgs, ... }:

    {
      imports = [
        ../../users/denbeigh/profiles/darwin.nix
      ];

      config = {
        dev.denbeigh = {
          machine = {
            work = true;
            hostname = "mutant";
            graphical = false;
          };

          user = {
            username = "denbeighstevens";
            keys = [ "id_ed25519" ];
          };

          # tailscale is enabled by default in darwin standard
        };

        system.primaryUser = "denbeighstevens";
        system.stateVersion = 5;
      };
    };

  meta.owners = with members; [ denbeigh ];
}
