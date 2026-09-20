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

  config = {
    # docker was previously always-on for NixOS machines (imported by
    # utils.nix); kept explicit now that modules/docker is enable-gated
    dev.denbeigh.docker.enable = true;

    networking = {
      hostName = cfg.machine.hostname;
      inherit (cfg.machine) domain;
    };

    services.chrony.enable = true;
    environment.wordlist.enable = true;
  };
}
