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
            hostname = "runt";
            graphical = false;
          };

          user = {
            username = "denbeigh.stevens";
            keys = [ "id_ed25519" ];
          };

          tailscale.enable = false;
        };

        system.primaryUser = "denbeigh.stevens";
        system.stateVersion = 5;
      };
    };

  meta.owners = with members; [ denbeigh ];
}
