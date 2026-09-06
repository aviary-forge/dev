{ dev, members, ... }:

dev.nix.nixos.eval {
  configuration =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    {
      imports = [
        ../../../modules/nixos/standard.nix
      ];

      config = {
        nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
        dev.denbeigh = {
          nix-cache.enable = false;
          ssh.enable = true;
          machine = {
            hostname = "esmerelda";
            location = dev.users.denbeigh.utils.locations.locations.sf;
          };
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

        # pi + extensions are managed by the home-manager module
        # (users/denbeigh/modules/home-manager/pi.nix)
        home-manager.users.denbeigh.programs.pi-coding-agent = {
          enable = true;
          myPackages = with dev.third_party.pi-extensions; [
            context-mode
            pi-intercom
            pi-mcp-adapter
            pi-prompt-template-model
            pi-subagents
            pi-rewind
            plannotator
            rpiv-ask-user-question
            rpiv-todo
          ];
        };

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
