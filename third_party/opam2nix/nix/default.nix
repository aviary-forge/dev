{ pkgs ? import <nixpkgs> {}, ocamlPackagesOverride ? null, ... }:
pkgs.callPackage ./nix (if ocamlPackagesOverride != null then {
  ocamlPackagesOverride = ocamlPackagesOverride;
} else { })
