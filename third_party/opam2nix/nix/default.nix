{
  pkgs ? import <nixpkgs> { },
  ocamlPackagesOverride ? null,
  ...
}:
pkgs.callPackage ./nix (
  if ocamlPackagesOverride != null then
    {
      inherit ocamlPackagesOverride;
    }
  else
    { }
)
