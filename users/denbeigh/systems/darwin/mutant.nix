{ dev, members, ... }:

dev.nix.darwin.eval {
  configuration =
    { pkgs, ... }:

    {
      imports = [
        ../../modules/nix-darwin/standard.nix
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
