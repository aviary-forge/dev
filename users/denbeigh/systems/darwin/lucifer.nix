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

        # pi + extensions are managed by the home-manager module
        # (users/denbeigh/modules/home-manager/pi.nix)
        home-manager.users.denbeigh.programs.pi-coding-agent = {
          enable = true;
          myPackages = with dev.third_party.pi-extensions; [
            context-mode
            pi-intercom
            pi-mcp-adapter
            pi-prompt-template-model
            pi-subagents
            pi-rewind
            plannotator
            rpiv-ask-user-question
            rpiv-todo
          ];
        };

        ids.gids.nixbld = 30000;
      };
    };

  meta.owners = with members; [ denbeigh ];
}
