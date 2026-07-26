{
  security.sudo.extraRules = [
    {
      users = [ "denbeigh" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  dev.denbeigh.nix-cache.enable = false;
}
