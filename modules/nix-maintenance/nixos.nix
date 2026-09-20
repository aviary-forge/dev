_: {
  nix.gc = {
    dates = "weekly";
    randomizedDelaySec = "45min";
  };

  nix.optimise = {
    dates = "weekly";
    randomizedDelaySec = "30min";
  };
}
