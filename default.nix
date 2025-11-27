{ ... }:

let
  readTree = import ./nix/readTree { };

  readRepo = args: readTree {
    inherit args;
    path = ./.;
    scopedArgs = {
      __findFile = _: _: throw "Do not import from NIX_PATH (<nixpkgs>) here!";
    };
  };
in
readTree.fix (self: (readRepo {
  dev = self;

  pkgs = self.third_party.nixpkgs;
  lib = self.third_party.nixpkgs.lib;
}))

