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
            hostname = "lucifer";
            location = dev.users.denbeigh.utils.locations.locations.sf;
          };
          user = {
            username = "denbeigh";
            keys = [ "id_ed25519" ];
          };
        };

        system.primaryUser = "denbeigh";
        system.stateVersion = 5;

        environment.systemPackages = with pkgs; [
          # llama-cpp-client
          opencode
          wireguard-tools
          wireguard-go
        ];

        home-manager.users.denbeigh.programs.pi-coding-agent.enable = true;

        ids.gids.nixbld = 30000;
      };
    };

  meta.owners = with members; [ denbeigh ];
}
