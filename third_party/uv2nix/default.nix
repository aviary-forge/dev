{ dev, lib, ... }:
import dev.third_party.nix.uv2nix {
  inherit lib;
  pyproject-nix = dev.third_party."pyproject-nix";
}
