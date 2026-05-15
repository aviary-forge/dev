{ dev, ... }:

dev.nix.nixos.eval (
  { pkgs
  , config
  , lib
  , modulesPath
  , ...
  }:
  let
    # TODO: move this to overlay?
    llama-cpp-patched = pkgs.callPackage ./llama-cpp.nix { };
  in
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

      environment.systemPackages =
        with pkgs;
        [
          vim
          nano
          nix
          git
          htop
          wget
          curl
          zsh
          llama-cpp-patched
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

      services.ollama = {
        enable = true;
        openFirewall = true;
        host = "0.0.0.0";
        acceleration = "cuda";
      };

      # services.llama-cpp = {
      #   enable = true;
      #   openFirewall = true;
      #   package = llama-cpp-patched;
      #   host = "0.0.0.0";
      #   port = 12274;
      # };

      networking.firewall.allowedTCPPorts = [ 8001 ];

      # Enable OpenGL
      hardware.graphics = {
        enable = true;
      };

      # Load nvidia driver for Xorg and Wayland
      services.xserver.videoDrivers = [ "nvidia" ];

      hardware.nvidia = {

        # Modesetting is required.
        modesetting.enable = true;


        # Nvidia power management. Experimental, and can cause sleep/suspend to fail.
        # Enable this if you have graphical corruption issues or application crashes after waking
        # up from sleep. This fixes it by saving the entire VRAM memory to /tmp/ instead 
        # of just the bare essentials.
        powerManagement.enable = false;

        # Fine-grained power management. Turns off GPU when not in use.
        # Experimental and only works on modern Nvidia GPUs (Turing or newer).
        powerManagement.finegrained = false;


        # Use the NVidia open source kernel module (not to be confused with the
        # independent third-party "nouveau" open source driver).
        # Support is limited to the Turing and later architectures. Full list of 
        # supported GPUs is at: 
        # https://github.com/NVIDIA/open-gpu-kernel-modules#compatible-gpus 
        # Only available from driver 515.43.04+
        open = false;

        # Enable the Nvidia settings menu,
        # accessible via `nvidia-settings`.
        nvidiaSettings = false;

        # Optionally, you may need to select the appropriate driver version for your specific GPU.
        package = config.boot.kernelPackages.nvidiaPackages.stable;
      };

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
