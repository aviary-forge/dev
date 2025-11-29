{ dev, pkgs, ... }:
{ config, ... }:

{
  imports = [
    (dev.third_party.agenix.src + "/modules/age.nix")
  ];

  config = {
    networking = {
      hostName = "aviary";
      domain = "denbeigh.cloud";
    };

    # TODO(denbeigh) transfer my dotfiles repo here
    users.users.denbeigh = {
      isNormalUser = true;
      group = "denbeigh";
      extraGroups = [ "wheel" ];
    };

    users.groups.denbeigh = { };

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

    age = {
      identityPaths = [ "/var/agenix/keys/id_ed25519" ];
      secrets =
        let
          inherit (builtins) listToAttrs map;
          includedSecrets = [
            "buildkite-agent-token"
            "buildkite-graphql-token"
            "buildkite-ssh-private-key"
          ];
          secret = name: {
            inherit name;
            value = { file = dev.secrets."${name}.age"; };
          };
        in
        listToAttrs (map secret includedSecrets);
    };


    services.openssh = {
      enable = true;
      openFirewall = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    boot.loader.efi.canTouchEfiVariables = true;
    boot.loader.systemd-boot.enable = true;

    boot.kernelPackages = pkgs.linuxPackages_latest;
    # The manual says this *must* be set, but we're using systemd-boot? :shrug:
    boot.loader.grub.device = "/dev/nvme0n1p1";

    # TODO: we probably want to configure this properly?
    networking.networkmanager.enable = true; # Easiest to use and most distros use this by default.
    networking.firewall.enable = true;


    time.timeZone = "UTC";

    i18n.defaultLocale = "en_US.UTF-8";
    console = {
      font = "Lat2-Terminus16";
      useXkbConfig = true; # use xkb.options in tty.
    };

    # Mostly generated from hardware-configuration
    boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usb_storage" "usbhid" "sd_mod" "sr_mod" ];
    boot.initrd.kernelModules = [ "dm-snapshot" ];
    boot.kernelModules = [ "kvm-intel" ];
    boot.extraModulePackages = [ ];

    fileSystems."/" = {
      device = "/dev/disk/by-uuid/47b7287a-dac5-40c2-9c6d-9234fda53763";
      # { device = "/dev/volgroup/cryptroot";
      fsType = "ext4";
    };

    boot.initrd.luks.devices."root" = {
      preLVM = false;
      device = "/dev/disk/by-uuid/6bbc9e9f-ca71-4a12-9fa0-ca05df1a4071";
    };

    fileSystems."/boot" = {
      device = "/dev/disk/by-uuid/1E47-0C51";
      fsType = "vfat";
      options = [ "fmask=0022" "dmask=0022" ];
    };

    swapDevices = [ ];

    # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
    # (the default) this is the recommended approach. When using systemd-networkd it's
    # still possible to use this option, but it's recommended to use it in conjunction
    # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
    networking.useDHCP = pkgs.lib.mkDefault true;
    # networking.interfaces.eno1.useDHCP = lib.mkDefault true;
    # networking.interfaces.eno2.useDHCP = lib.mkDefault true;
    # networking.interfaces.enp0s20f0u8u3c2.useDHCP = lib.mkDefault true;

    nixpkgs.hostPlatform = pkgs.lib.mkDefault "x86_64-linux";
    hardware.cpu.intel.updateMicrocode = pkgs.lib.mkDefault config.hardware.enableRedistributableFirmware;

    system.stateVersion = "25.05"; # Did you read the comment?
  };
}
