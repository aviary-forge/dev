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
            hostname = "pablo";
            graphical = true;
            location = dev.users.denbeigh.utils.locations.locations.sf;
          };

          user = {
            username = "denbeigh";
            keys = [ "id_ed25519" ];
          };

          tailscale.enable = false;
        };

        system.primaryUser = "denbeigh";
        system.stateVersion = 5;

        # clyde (the discord monorepo's bootstrap tool) owns nix here: the
        # Determinate installer wrote /etc/nix/nix.conf and chowned /nix to me,
        # so the daemon is vestigial. If nix-darwin rewrites nix.conf it drops
        # `extra-trusted-users = denbeigh`, clyde's runtime `extra-substituters`
        # are then ignored, and every monorepo build misses the private cache.
        nix.enable = false;

        # nix.enable = false also drops baseModule's nixPath, which is what
        # points `nix-shell -p` at the monorepo's pinned nixpkgs.
        # NB: clyde's wrapper reuses $NIX_PATH as a local for the nix store root
        # and exports it, so anything run through ~/.nix-profile/bin/nix ignores
        # this. Use /nix/var/nix/profiles/default/bin/nix for personal work.
        environment.variables.NIX_PATH = "nixpkgs=${dev.path + "/third_party/nixpkgs/global.nix"}";

        # modules/common/standard.nix normally lands these in /etc/nix/nix.conf,
        # which nothing writes now. clyde only ever writes ~/.config/nix/netrc,
        # so the user-level config is uncontested.
        home-manager.users.denbeigh.nix = {
          # only used to generate nix.conf; the nix actually on PATH here is
          # clyde's wrapper out of ~/.nix-profile.
          package = pkgs.nix;
          # Use the `extra-` forms. nix-darwin's `nix.settings.*` are list
          # options whose defaults the module system merges into, but Home
          # Manager's `nix.settings` is freeform: a bare `trusted-public-keys`
          # here REPLACES the built-in list, drops the cache.nixos.org key, and
          # every substitute is then rejected as unsigned.
          settings = {
            extra-experimental-features = [
              "nix-command"
              "flakes"
            ];
            extra-trusted-public-keys = [
              "remote-build:gmaC+UE4JxbR6wcMtuZ6WZF0nL1Jh2D3REY9zdwZFWg="
            ];
          };
        };
      };
    };

  meta.owners = with members; [ denbeigh ];
}
