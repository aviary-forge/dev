{ dev, ... }:

dev.nix.nixos.eval (
  { pkgs, config, lib, ... }:

  {
    imports = [
      ../../../modules/nixos/standard.nix
      ../../../modules/nixos/development.nix
      ../../../modules/nixos/tailscale.nix
      ../../../modules/nixos/gaming.nix
    ];

    config = {
      dev.denbeigh = {
        machine = {
          hostname = "martha";
          graphical = true;
          location = dev.users.denbeigh.utils.locations.locations.sf;
        };
        ssh.enable = true;
        tailscale.enable = true;
      };

      age.identityPaths = [ "/home/denbeigh/.ssh/id_ed25519" ];

      # ── Hardware (from nixos-generate-config) ─────────────────────
      boot.loader.systemd-boot.enable = true;

      boot.initrd.availableKernelModules = [
        "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" "sdhci_pci"
      ];
      boot.initrd.kernelModules = [ ];
      boot.kernelModules = [ "kvm-intel" ];
      boot.extraModulePackages = [ ];

      fileSystems."/" = {
        device = "/dev/disk/by-uuid/82560cd3-7484-406c-87fa-7e4f74b58f7e";
        fsType = "ext4";
      };

      fileSystems."/home" = {
        device = "/dev/disk/by-uuid/e59f05c4-a0b1-4a92-863f-e82ac47cf82c";
        fsType = "ext4";
      };

      fileSystems."/boot" = {
        device = "/dev/disk/by-uuid/D27B-62E4";
        fsType = "vfat";
      };

      swapDevices = [ ];

      networking.useDHCP = lib.mkDefault true;

      nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
      hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

      system.stateVersion = "23.05";
    };
  }
)
