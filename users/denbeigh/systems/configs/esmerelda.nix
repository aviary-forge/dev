{ dev, ... }:

dev.nix.nixos.eval (
  {
    pkgs,
    config,
    lib,
    modulesPath,
    ...
  }:
  {
    imports = [
      # ../../modules/nixos/standard.nix
    ];

    config = {
      networking = {
        hostName = "esmerelda";
        domain = "sfo.denbeigh.cloud";
      };
      # dev.denbeigh = {
      #   machine = {
      #     hostname = "esmerelda";
      #     location = dev.users.denbeigh.utils.locations.locations.sf;
      #   };
      #   user = {
      #     username = "denbeigh";
      #     keys = [ "id_ed25519" ];
      #   };
      # };

      environment.systemPackages = with pkgs; [
        vim
        nano
        nix
        git
        htop
        wget
        curl
        zsh
      ];

      services.openssh = {
        enable = true;
        openFirewall = true;
        settings = {
          PasswordAuthentication = false;
          PermitRootLogin = "no";
        };
      };
      programs.zsh.enable = true;

      system.stateVersion = "25.11"; # Did you read the comment?

      # Use the systemd-boot EFI boot loader.
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;

      users.users.denbeigh = {
        isNormalUser = true;
        description = "Alice";
        extraGroups = [ "wheel" ]; # Sudo access
        shell = pkgs.zsh;
        home = "/home/denbeigh";
      };

      users.groups.denbeigh = { };

      boot.initrd.availableKernelModules = [
        "xhci_pci"
        "ahci"
        "nvme"
        "usb_storage"
        "usbhid"
        "sd_mod"
      ];
      boot.initrd.kernelModules = [ ];
      boot.kernelModules = [ "kvm-intel" ];
      boot.extraModulePackages = [ ];

      fileSystems."/" = {
        device = "/dev/disk/by-label/NIXROOT";
        fsType = "ext4";
      };

      fileSystems."/boot" = {
        device = "/dev/disk/by-label/NIXBOOT";
        fsType = "vfat";
        options = [
          "fmask=0022"
          "dmask=0022"
        ];
      };

      swapDevices = [ ];

      nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
      hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
    };
  }
)
