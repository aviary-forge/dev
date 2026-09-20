{ config, lib, ... }:

let
  inherit (lib)
    mkDefault
    mkIf
    ;

  cfg = config.dev.ssh;
in
{
  config = {
    services.openssh = {
      # Set if enabled
      enable = mkIf cfg.enable true;
      ports = mkIf cfg.enable [ cfg.sshPort ];
      openFirewall = mkIf cfg.enable true;

      # Preferred security defaults, should be set regardless
      settings = {
        PermitRootLogin = mkDefault "no";
        PasswordAuthentication = mkDefault false;
        KbdInteractiveAuthentication = mkDefault false;
      };
    };
  };
}
