let
  name = "Denbeigh Stevens";
  email = "denbeigh@denbeighstevens.com";
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
