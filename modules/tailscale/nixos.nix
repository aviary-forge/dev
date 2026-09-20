# NixOS-specific tailscale wiring: auth key + auto-login, firewall exemptions.
# Where the auth key comes from (age secret, file) is persona/machine policy,
# set via dev.denbeigh.tailscale.authKeyFile.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dev.denbeigh.tailscale;
in
{
  config = lib.mkIf cfg.enable {
    networking.firewall = {
      checkReversePath = "loose";
      trustedInterfaces = [ config.services.tailscale.interfaceName ];
      allowedUDPPorts = [ config.services.tailscale.port ];
    };

    # Adapted from https://tailscale.com/blog/nixos-minecraft/
    systemd.services.tailscale-login = lib.mkIf (cfg.authKeyFile != null) {
      description = "Automatic connection to Tailscale";

      # make sure tailscale is running before trying to connect to tailscale
      after = [
        "network-pre.target"
        "tailscale.service"
      ];
      wants = [
        "network-pre.target"
        "tailscale.service"
      ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig.Type = "oneshot";

      script = with pkgs; ''
        # wait for tailscaled to settle
        sleep 2

        # check if we are already authenticated to tailscale
        status="$(${pkgs.tailscale}/bin/tailscale status -json | ${pkgs.jq}/bin/jq -r .BackendState)"
        if [ $status = "Running" ]; then
          exit 0
        fi

        ${pkgs.tailscale}/bin/tailscale up -authkey "$(< ${cfg.authKeyFile})"
      '';
    };
  };
}
