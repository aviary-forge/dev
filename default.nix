{
  localSystem ? builtins.currentSystem,
  ...
}:

# Adapted from work by the TVL authors. Copyright remains until this file is
# Ship of Theseus'd

let
  readTree = import ./nix/readTree { };

  readRepo =
    args:
    readTree {
      inherit args;
      path = ./.;
      scopedArgs = {
        __findFile = _: _: throw "Do not import from NIX_PATH (<nixpkgs>) here!";
        builtins = builtins // {
          currentSystem = throw "use injected localSystem from readTree, not currentSystem";
        };
      };
    };

  eligibleForCi =
    target:
    # filter so we only build things that actually _build things_
    (target ? outPath)
    # filter so we do not build broken things
    && !(target.meta.broken or false);
in

readTree.fix (
  self:
  (readRepo {
    inherit localSystem;
    dev = self;

    pkgs = self.third_party.nixpkgs;
    lib = self.third_party.nixpkgs.lib;

    # Convenience/nice to have this at a top level
    members = import ./members.nix;
  })
  // rec {

    path = self.third_party.nixpkgs.lib.cleanSourceWith {
      name = "dev";
      src = ./.;
      filter = self.third_party.nixpkgs.lib.cleanSourceFilter;
    };

    ci =
      let
        excluded = [
          # e.g.: self.path.to.package
        ];
        targets' = readTree.gather (
          target: ((eligibleForCi target) && (!builtins.elem target excluded))
        ) self;

        # Ensure the tool that needs to evaluate `ci.targets`
        # does not get included in `ci.targets`
        targets =
          let
            inherit (self.third_party.nixpkgs.lib.lists) hasPrefix;
            notInPipelines = e: !(hasPrefix [ "pipelines" ] e.__readTree);
          in
          builtins.filter notInPipelines targets';

        # Derivation that gcroots all built targets.
        gcroot =
          with self.third_party.nixpkgs;
          writeText "monorepo-gcroot" (
            builtins.concatStringsSep "\n" (
              lib.flatten (
                map (p: map (o: p.${o}) p.outputs or [ ]) # list all outputs of each drv
                  targets
              )
            )
          );

      in
      {
        inherit excluded targets gcroot;
      };

    systems =
      let
        mkSystemDiscovery = isSystemPredicate:
          let
            targets' = readTree.gather isSystemPredicate self;

            byPath =
              let
                paths = map (t:
                  let
                    p = builtins.concatStringsSep "." t.__readTree;
                  in
                  if p != "" then
                    {
                      name = p;
                      value = t;
                    }
                  else
                    null
                ) targets';
              in
              builtins.listToAttrs (builtins.filter (x: x != null) paths);
          in
          {
            targets = targets';
            byPath = byPath;
          };
      in
      {
        nixos = mkSystemDiscovery (target: target ? __devAttrType && target.__devAttrType == "nixos-system");
        darwin = mkSystemDiscovery (target: target ? __devAttrType && target.__devAttrType == "darwin-system");
        "home-manager" = mkSystemDiscovery (target: target ? __devAttrType && target.__devAttrType == "home-manager-system");
      };

    ownership =
      let
        targetList = builtins.map (t: {
          path = t.__readTree;
          deriv = t;
        }) ci.targets;
      in
      self.nix.owners.buildReport targetList;
  }
)
