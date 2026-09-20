{ dev, members, ... }:

dev.nix.nixos.eval {
  # Platform declared as data: reading .system on the target must not force
  # the module fixpoint (CI drvmap filters foreign systems without eval).
  system = "x86_64-linux";

  configuration =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    {
      imports = [
        ../../users/denbeigh/profiles/nixos.nix
      ];

      config = {
        nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
        dev.denbeigh = {
          machine = {
            hostname = "esmerelda";
            location = dev.users.denbeigh.utils.locations.locations.sf;
          };
        };
        dev = {
          nix-cache.enable = false;
          ssh.enable = true;
        };

        environment.systemPackages = with pkgs; [
          vim
          nano
          nix
          git
          htop
          wget
          curl
          zsh
          llama-cpp-server
          python3Packages.huggingface-hub
        ];

        home-manager.users.denbeigh.programs.pi-coding-agent.enable = true;

        services.openssh = {
          enable = true;
          openFirewall = true;
          settings = {
            PasswordAuthentication = false;
            PermitRootLogin = "no";
          };
        };
        programs.zsh.enable = true;

        # Experimenting with llama-cpp before committing
        networking.firewall.allowedTCPPorts = [ 8001 ];

        # Enable OpenGL + NVIDIA
        hardware = {
          graphics.enable = true;
          nvidia = {
            modesetting.enable = true;
            powerManagement.enable = false;
            powerManagement.finegrained = false;
            open = false;
            nvidiaSettings = false;
            package = config.boot.kernelPackages.nvidiaPackages.stable;
          };
          cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
        };

        # Load nvidia driver for Xorg and Wayland
        services.xserver.videoDrivers = [ "nvidia" ];

        system.stateVersion = "25.11"; # Did you read the comment?

        boot = {
          loader.systemd-boot.enable = true;
          loader.efi.canTouchEfiVariables = true;
          initrd.availableKernelModules = [
            "xhci_pci"
            "ahci"
            "nvme"
            "usb_storage"
            "usbhid"
            "sd_mod"
          ];
          initrd.kernelModules = [ ];
          kernelModules = [ "kvm-intel" ];
          extraModulePackages = [ ];
        };

        users.users.denbeigh = {
          isNormalUser = true;
          description = "Alice";
          extraGroups = [ "wheel" ];
          home = "/home/denbeigh";
        };

        users.groups.denbeigh = { };

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
      };
    };

  meta = {
    owners = with members; [ denbeigh ];
    # I don't really want to build this most of the time, because the
    # source-built llama-cpp makes builds very slow.
    ci.skip = true;
  };
}
