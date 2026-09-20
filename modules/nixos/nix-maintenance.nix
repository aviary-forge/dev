# Periodic nix store maintenance: garbage collection + store optimisation.
# Runs `nix-collect-garbage --delete-older-than 30d` as root weekly; anything
# that needs to survive GC must have a gcroot (e.g. the CI dev gcroot).
_: {
  nix.gc = {
    automatic = true;
    dates = "weekly";
    randomizedDelaySec = "45min";
    options = "--delete-older-than 30d";
  };

  nix.optimise = {
    automatic = true;
    dates = "weekly";
    randomizedDelaySec = "30min";
  };
}
