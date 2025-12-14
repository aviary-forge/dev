{ dev, ... }:

dev.nix.darwin.eval (
  { pkgs, ... }:
  {
    networking =
      {
        hostName = "builder";
        domain = "sfo.denbeigh.cloud";
      };

    environment.systemPackages = [ pkgs.stdenv pkgs.git ];
    services.openssh.enable = true;

    system.defaults = {
      loginwindow.autoLoginUser = "denbeigh";
      NSGlobalDomain.NSDocumentSaveNewDocumentsToCloud = false;
      WindowManager.EnableStandardClickToShowDesktop = false;
      SoftwareUpdate.AutomaticallyInstallMacOSUpdates = false;
      dock = {
        persistent-apps = [ ];
        persistent-others = [ ];
      };
      universalaccess.reduceTransparency = true;
    };

    time.timeZone = "GMT";
    users.users.denbeigh = {
      packages = [ dev.users.denbeigh.neovim ];
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBrWuq0cLFKo4KKLYKF/SG3U/6/7U0o7JDHDeJOwadAf"
      ];
    };

    system.stateVersion = 6;
    system.primaryUser = "denbeigh";
  }
)
