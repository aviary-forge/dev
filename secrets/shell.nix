{
  dev ? import ../. { },
  ...
}:

let
  pkgs = dev.third_party.nixpkgs;
in
pkgs.mkShell {
  packages = [
    dev.third_party.agenix.cli
    pkgs.age
  ];
}
