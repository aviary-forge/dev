{ dev, pkgs, ... }:
let

  darwin-tools = pkgs.callPackage (dev.third_party.nix.darwin + "/pkgs/nix-tools") { };
  eval =
    { configuration, specialArgs ? { } }:
    let
      eval = import (dev.third_party.nix.darwin + "/eval-config.nix") {
        inherit pkgs specialArgs;
        inherit (pkgs) lib;

        modules = [
          configuration
        ];
      };

    in
    {
      inherit (eval) system;
      inherit (eval.config.system.build) toplevel;
    };

in

{
  inherit eval;
  inherit (darwin-tools) darwin-option darwin-rebuild darwin-version;
}
