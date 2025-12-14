{ dev, ... }:

dev.nix.darwin.eval {
  networking = {
    hostName = "builder";
    domain = "sfo.denbeigh.cloud";
  };

  services.openssh.enable = true;

  users.users.denbeigh = {
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBrWuq0cLFKo4KKLYKF/SG3U/6/7U0o7JDHDeJOwadAf"
    ];
  };

  system.stateVersion = 6;
}
