{ dev, members, ... }:

dev.nix.nixos.eval {
  configuration =
    {
      pkgs,
      config,
      lib,
      ...
    }:

    let
      ciGroupName = "ci-agents";
    in

    {
      imports = [
        # Personal NixOS standard module chain (agenix, user, home-manager, common config)
        ../../users/denbeigh/modules/nixos/standard.nix

        # Services
        ../../users/denbeigh/modules/nixos/tailscale.nix
        ../../users/denbeigh/modules/nixos/ahoy.nix
        ../../users/denbeigh/modules/nixos/nix-cache.nix
        ../../users/denbeigh/modules/nixos/terraform.nix
        ../../users/denbeigh/modules/nixos/update-fonts.nix
        # ../../users/denbeigh/modules/nixos/3rdparty/cfdyndns  # disabled: key rotation

        # Infrastructure
        ../modules/nixos/ci
        ../modules/nixos/reverse-proxy
      ];

      config = {
        # ── Machine identity ──────────────────────────────────────────
        dev.denbeigh = {
          machine = {
            hostname = "aviary";
            domain = "denbeigh.cloud";
            location = dev.users.denbeigh.utils.locations.locations.utc;
            graphical = false;
          };

          ssh.enable = true;
          tailscale.enable = true;
          ahoy.enable = true;

          services = {
            nix-cache = {
              enable = true;
              keyFile = "/var/lib/denbeigh/nix-cache/serve-key";
            };

            # cfdyndns = {
            #   enable = true;
            #   records = [ "aviary.denbeigh.cloud" ];
            #   secretKeyPath = config.age.secrets.cfdyndnsApiToken.path;
            # };
          };
        };

        services.dev.reverse-proxy = {
          enable = true;
          baseDomain = "denbeigh.cloud";
          tailscaleAddr = "100.71.134.67";
          openFirewall = true;

          defaultVhost = {
            serverName = "_";
            return = "444";
          };

          acme = {
            enable = true;
            email = "denbeigh+letsencrypt@denbeighstevens.com";
            dnsProvider = "digitalocean";
            credentialFiles = {
              "DO_AUTH_TOKEN_FILE" = config.age.secrets.digitalOceanKey.path;
            };
          };
        };

        # ── CI ────────────────────────────────────────────────────────
        services.dev.ci = {
          enable = true;
          tokenPath = config.age.secrets.buildkite-agent-token.path;
          privateSshKeyPath = config.age.secrets.buildkite-ssh-private-key.path;
          groupName = ciGroupName;
        };

        # ── Secrets ───────────────────────────────────────────────────
        age = {
          identityPaths = [ "/var/agenix/keys/id_ed25519" ];
          secrets =
            let
              inherit (builtins) listToAttrs map;
              secret = name: {
                inherit name;
                value = {
                  file = dev.secrets."${name}.age";
                  group = ciGroupName;
                  mode = "640";
                };
              };
            in
            listToAttrs (
              map secret [
                "buildkite-agent-token"
                "buildkite-graphql-token"
                "buildkite-ssh-private-key"
              ]
            )
            # DigitalOcean API token for ACME DNS-01 challenge
            // {
              digitalOceanKey = {
                file = dev.secrets."digitalOceanAPIKey.age";
              };
            };
        };

        # ── Data directories ──────────────────────────────────────────
        systemd.tmpfiles.rules = [
          "d /data 0755 root root -"
          "d /data/downloads 0770 transmission media -"
          "d /data/media 0775 root media -"
        ];

        # ── System packages (beyond what standard module provides) ────
        environment.systemPackages = with pkgs; [
          vim
          nano
          htop
          wget
          curl
        ];

        networking.firewall.enable = true;

        # ── Locale / console ──────────────────────────────────────────
        i18n.defaultLocale = "en_US.UTF-8";
        console = {
          font = "Lat2-Terminus16";
          useXkbConfig = true;
        };

        # ── Hardware ──────────────────────────────────────────────────
        boot.loader.efi.canTouchEfiVariables = true;
        boot.loader.systemd-boot.enable = true;

        boot.kernelPackages = pkgs.linuxPackages_latest;
        # The manual says this *must* be set, but we're using systemd-boot
        boot.loader.grub.device = "/dev/nvme0n1p1";

        networking.networkmanager.enable = true;

        boot.initrd.availableKernelModules = [
          "xhci_pci"
          "ahci"
          "nvme"
          "usb_storage"
          "usbhid"
          "sd_mod"
          "sr_mod"
        ];
        boot.initrd.kernelModules = [ "dm-snapshot" ];
        boot.kernelModules = [ "kvm-intel" ];
        boot.extraModulePackages = [ ];

        fileSystems."/" = {
          device = "/dev/disk/by-uuid/47b7287a-dac5-40c2-9c6d-9234fda53763";
          fsType = "ext4";
        };

        boot.initrd.luks.devices."root" = {
          device = "/dev/disk/by-uuid/6bbc9e9f-ca71-4a12-9fa0-ca05df1a4071";
        };

        fileSystems."/boot" = {
          device = "/dev/disk/by-uuid/1E47-0C51";
          fsType = "vfat";
          options = [
            "fmask=0022"
            "dmask=0022"
          ];
        };

        swapDevices = [ ];

        networking.useDHCP = pkgs.lib.mkDefault true;

        nixpkgs.hostPlatform = pkgs.lib.mkDefault "x86_64-linux";
        hardware.cpu.intel.updateMicrocode = pkgs.lib.mkDefault config.hardware.enableRedistributableFirmware;

        system.stateVersion = "25.05";
      };
    };

  meta.owners = with members; [ denbeigh ];
}
