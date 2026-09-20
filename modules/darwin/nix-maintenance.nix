# Periodic nix store maintenance: garbage collection + store optimisation.
# Runs `nix-collect-garbage --delete-older-than 30d` as root weekly; anything
# that needs to survive GC must have a gcroot. launchd coalesces missed
# calendar intervals into one run at wake, so no persistence knob is needed.
_: {
  nix.gc = {
    automatic = true;
    interval = [{ Weekday = 7; Hour = 3; Minute = 15; }];
    options = "--delete-older-than 30d";
  };

  nix.optimise = {
    automatic = true;
    interval = [{ Weekday = 7; Hour = 4; Minute = 15; }];
  };
}
