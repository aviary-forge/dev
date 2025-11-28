{ localSystem ? builtins.currentSystem
, ...
}:

# Adapted from work by the TVL authors. Copyright remains until this file is
# Ship of Theseus'd

let
  readTree = import ./nix/readTree { };

  readRepo = args: readTree {
    inherit args;
    path = ./.;
    scopedArgs = {
      __findFile = _: _: throw "Do not import from NIX_PATH (<nixpkgs>) here!";
      builtins = builtins // {
        currentSystem = throw "use injected localSystem from readTree, not currentSystem";
      };
    };
  };

  eligibleForCi = target:
    # filter so we only build things that actually _build things_
    (target ? outPath)
    # filter so we do not build broken things
    && !(target.meta.broken or false);
in

readTree.fix
  (self: (readRepo {
    dev = self;

    pkgs = self.third_party.nixpkgs;
    lib = self.third_party.nixpkgs.lib;

    # Convenience/nice to have this at a top level
    members = import ./members.nix;
  }) // rec {
    inherit localSystem;

    path = self.third_party.nixpkgs.lib.cleanSourceWith {
      name = "dev";
      src = ./.;
      filter = self.third_party.nixpkgs.lib.cleanSourceFilter;
    };

    ci = rec {
      excluded = [
        # e.g.: self.path.to.package
      ];
      targets = readTree.gather
        (target: ((eligibleForCi target) &&
          (!builtins.elem target excluded))
        )
        self;
    };

    ownership =
      let targetList = builtins.map (t: { path = t.__readTree; deriv = t; }) ci.targets;
      in self.nix.owners.buildReport targetList;
  })
