{
  devPath ? ../.,
  systems ? [ builtins.currentSystem ],
}:

let
  inherit (builtins) unsafeDiscardStringContext;

  collateTargetMeta =
    mkLabel: target:
    let
      treePath = unsafeDiscardStringContext (mkLabel target);
      getOwners = target: if target.meta ? owners then target.meta.owners else [ ];
    in
    {
      name = treePath;
      value = {
        inherit treePath;
        system = unsafeDiscardStringContext target.system;
        drvPath = unsafeDiscardStringContext target.drvPath;
        outputPath = unsafeDiscardStringContext target.outPath;
        owners = getOwners target;
      };
    };

  evaluateSystem =
    system:
    let
      localDev = import devPath { localSystem = system; };
      inherit (localDev.nix.readTree) mkLabel;
      # TODO: do we want to invoke readTree.gather here, instead of in root?
      inherit (localDev.ci) targets;
    in
    {
      name = system;
      value = builtins.listToAttrs (builtins.map (collateTargetMeta mkLabel) targets);
    };

  evaluateAllSystems = systems: builtins.listToAttrs (builtins.map evaluateSystem systems);
in

evaluateAllSystems systems
