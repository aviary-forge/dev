{
  dev ? (import ../../.. { }),
}:

let
  pkgs = dev.third_party.nixpkgs;
in
pkgs.mkShell {
  packages = with pkgs.python314Packages; [
    uv
    python
  ];
}
