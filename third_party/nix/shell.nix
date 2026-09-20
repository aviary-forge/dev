{
  dev ? import ../.. { },
  ...
}:

let
  inherit (dev.third_party.nixpkgs) mkShell niv;

in
mkShell {
  packages = [
    niv
  ];

  meta.owners = with dev.members; [ denbeigh ];
}
