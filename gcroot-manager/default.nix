{ dev, ... }:

dev.third_party.naersk.buildPackage {
  src = ./.;
}
