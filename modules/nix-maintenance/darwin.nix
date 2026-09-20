_: {
  nix.gc.interval = [
    {
      Weekday = 7;
      Hour = 3;
      Minute = 15;
    }
  ];

  nix.optimise.interval = [
    {
      Weekday = 7;
      Hour = 4;
      Minute = 15;
    }
  ];
}
