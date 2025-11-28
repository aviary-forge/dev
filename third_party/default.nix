{ pkgs, localSystem, ... }:

{
  nixos =
    { configuration
    , specialArgs ? { }
    , system ? localSystem
    , ...
    }:
    let
      eval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
        inherit specialArgs system;
        modules = [
          configuration
          # NOTE: here is where we can inject our repo-specific modules, when
          # we are ready
        ];
      };

      vmConfig = import (pkgs.path + "/nixos/lib/eval-config.nix") {
        inherit specialArgs system;
        modules = [
          configuration
          (pkgs.path + "/nixos/modules/virtualisation/qemu-vm.nix")
        ];
      };
    in
    {
      inherit (eval) pkgs config options;
      system = eval.config.system.build.toplevel;
      vm = vmConfig.system.build.vm;
    };
}
