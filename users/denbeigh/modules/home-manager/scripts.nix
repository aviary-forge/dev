{ dev, ... }:

{
  home.packages = with dev.users.denbeigh.scripts; [
    gitignore
    roulette
    grid
  ];
}
