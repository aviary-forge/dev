{ dev, ... }:

dev.nix.darwin.eval (
  { pkgs, ... }:
  {
    imports = [
      ../../modules/nix-darwin/standard.nix
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
        ollama
        opencode
      ];

      ids.gids.nixbld = 30000;
    };
  }
)
