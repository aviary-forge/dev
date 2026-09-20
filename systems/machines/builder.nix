{ dev, members, ... }:

dev.nix.darwin.eval {
  configuration =
    { pkgs, ... }:

    {
      imports = [
        ../../users/denbeigh/profiles/darwin.nix
      ];
      config = {
        dev.denbeigh = {
          machine = {
            location = dev.users.denbeigh.utils.locations.locations.utc;
            hostname = "builder";
          };
        };
        dev = {
          tailscale.enable = false;
          # Periodic store GC/optimisation
          nix-maintenance.enable = true;
        };
        networking.domain = "sfo.denbeigh.cloud";

        environment.systemPackages = [
          pkgs.stdenv
          pkgs.stdenv.cc
          pkgs.git
        ];
        services.openssh.enable = true;

        system = {
          defaults.loginwindow.autoLoginUser = "denbeigh";
          stateVersion = 6;
          primaryUser = "denbeigh";
        };

        users.users.denbeigh = {
          packages = [ dev.users.denbeigh.neovim ];
          openssh.authorizedKeys.keys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBrWuq0cLFKo4KKLYKF/SG3U/6/7U0o7JDHDeJOwadAf"
          ];
        };
      };
    };

  meta.owners = with members; [ denbeigh ];
}
