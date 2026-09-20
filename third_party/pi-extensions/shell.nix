{
  dev ? import ../.. { },
  ...
}:

dev.third_party.nixpkgs.mkShell {
  packages = [
    dev.tools.pi-extensions-update
  ];
  meta.owners = with dev.members; [ denbeigh ];
}
