{ dev, ... }:

let
  inherit (dev.third_party.naersk) buildPackage;
  inherit (dev.third_party.nixpkgs.lib) cleanSource;
in
buildPackage {
  src = (cleanSource ./.);
}
