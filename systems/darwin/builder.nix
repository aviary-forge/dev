{ dev, members, ... }:

dev.nix.darwin.eval {
  configuration =
  { pkgs, ... }:

  {
    imports = [
      ../../users/denbeigh/modules/nix-darwin/standard.nix
    ];
    config = {
      dev.denbeigh = {
        tailscale.enable = false;
        machine = {
          location = dev.users.denbeigh.utils.locations.locations.utc;
          hostname = "builder";
        };
      };
      networking.domain = "sfo.denbeigh.cloud";

      environment.systemPackages = [
        pkgs.stdenv
        pkgs.stdenv.cc
        pkgs.git
      ];
      services.openssh.enable = true;

      system.defaults.loginwindow.autoLoginUser = "denbeigh";

      users.users.denbeigh = {
        packages = [ dev.users.denbeigh.neovim ];
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBrWuq0cLFKo4KKLYKF/SG3U/6/7U0o7JDHDeJOwadAf"
        ];
      };

      system.stateVersion = 6;
      system.primaryUser = "denbeigh";
    };
  };

  meta.owners = with members; [ denbeigh ];
}
