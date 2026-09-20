# Periodic nix store maintenance: garbage collection + store optimisation.
# Runs `nix-collect-garbage --delete-older-than 30d` as root weekly; anything
# that needs to survive GC must have a gcroot (e.g. the CI dev gcroot). On
# darwin, launchd coalesces missed calendar intervals into one run at wake,
# so no persistence knob exists or is needed.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  # pkgs, not config: reading config in imports recurses; the repo doesn't
  # cross-eval, so pkgs' hostPlatform always matches the target machine.
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in
{
  imports = lib.optionals isDarwin [ ./darwin.nix ] ++ lib.optionals (!isDarwin) [ ./nixos.nix ];

  options.dev.nix-maintenance.enable = lib.mkEnableOption "periodic nix store maintenance";

  config = lib.mkIf config.dev.nix-maintenance.enable {
    nix.gc = {
      automatic = true;
      options = "--delete-older-than 30d";
    };

    nix.optimise.automatic = true;
  };
}
