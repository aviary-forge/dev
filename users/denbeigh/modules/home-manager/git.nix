{ config, ... }:

let
  inherit (config.dev.denbeigh.machine) work;
  workEmail = "denbeigh.stevens@discordapp.com";
  personalEmail = "denbeigh@denbeighstevens.com";

  name = "Denbeigh Stevens";
  email = if work then workEmail else personalEmail;
in
{
  programs.git = {
    enable = true;
    settings = {
      user = { inherit name email; };
      help.autocorrect = -1;
      merge.ff = "only";
      fetch.prune = true;
    };
  };
}
