{ dev, config, ... }:

{
  imports = [
    (dev.third_party.nix.fonts + "/update/module.nix")
    (dev.third_party.agenix.src + "/modules/age.nix")
  ];

  config =
    let
      user = "font-updater";
    in
    {
      age.secrets.fontDeployKey = {
        file = ../../secrets/fontDeployKey.age;
        owner = user;
        mode = "600";
      };

      denbeigh.services.updaters.fonts = {
        enable = true;
        sshKeyPath = config.age.secrets.fontDeployKey.path;
        inherit user;
      };
    };
}
