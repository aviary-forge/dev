{ dev, lib, ... }:
import dev.third_party.nix."pyproject-build-systems" {
  inherit lib;
  uv2nix = dev.third_party.uv2nix;
  pyproject-nix = dev.third_party."pyproject-nix";
}
