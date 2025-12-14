{ dev, ... }:

dev.nix.darwin.eval {
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

    ids.gids.nixbld = 30000;
  };
}
