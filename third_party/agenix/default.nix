{ pkgs, dev, ... }:

let
  src = dev.third_party.nix.agenix;

  agenix = import src {
    inherit pkgs;
  };
in
{
  # NOTE: required for importing module in NixOS configurations
  inherit src;
  cli = agenix.agenix;
}

