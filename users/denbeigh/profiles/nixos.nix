{
  dev,
  config,
  lib,
  ...
}:

let
  inherit (lib) mkOption types;
  cfg = config.dev.denbeigh;
in

{
  imports = [
    (dev.third_party.agenix.src + "/modules/age.nix")

    ../../../modules/all.nix
    ../../../modules/common/standard.nix
    ../modules/common/variables.nix
    ../modules/nixos/denbeigh.nix
    ../modules/nixos/utils.nix
    ../modules/nixos/graphical.nix
    ../modules/nixos/webcam.nix
  ];

  options.dev.denbeigh.machine = {
    domain = mkOption {
      type = types.str;
      default = "sfo.denbeigh.cloud";
      description = ''
        Networking domain of the machine.
      '';
    };
  };

  config = lib.mkMerge [
    {
      # docker was previously always-on for NixOS machines (imported by
      # utils.nix); kept explicit now that modules/docker is enable-gated
      dev = {
        docker.enable = true;
        nix-cache.enable = !config.dev.nix-cache-serve.enable;
      };

      networking = {
        hostName = cfg.machine.hostname;
        inherit (cfg.machine) domain;
      };

      services.chrony.enable = true;
      environment.wordlist.enable = true;
    }

    (lib.mkIf config.dev.tailscale.enable {
      # persona wiring for the universal tailscale module: auth key comes
      # from the repo secrets store, decrypted at runtime by agenix
      age.secrets.tailscaleAuthKey.file = dev.secrets."tailscaleAuthKey.age";
      dev.tailscale.authKeyFile = config.age.secrets.tailscaleAuthKey.path;
    })

    # persona value for the universal nix-cache serve-side module: the
    # remote-build upload key
    {
      dev.nix-cache-serve.receiverAuthorizedKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHn3tzQJW1Fwt3n5xSK+V6MhS7ULddEW0mTNcrigHbp0"
      ];
    }
  ];
}
