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

  dev.nix-cache.enable = false;
}
