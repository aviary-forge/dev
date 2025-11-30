{ dev, pkgs, ... }:

let
  inherit (pkgs.lib) concatStringsSep;
  # targets: [{
  #   path = ["nix" "owners" ];
  #   derivation = <deriv>;
  # }] -> [owners]
  evaluateTarget = target:
    # let
    #   owners = 
    # in
    {
      inherit (target) path;
      inherit (target.deriv.meta) owners;
    };

  formatPath = { path, ... }:
    concatStringsSep "." path;

  formatUnownedMsg = targets:
    let
      pathList = [ "" ] ++ map formatPath targets;
      pathMsg = concatStringsSep "\n - " pathList;
    in
    "The following packages are unowned:\n${pathMsg}";

  isUnowned = { deriv, ... }:
    let
      owners = deriv.meta.owners or [ ];
    in
    (builtins.isNull owners || ((builtins.length owners) == 0));

  evaluate = targets:
    let
      unownedTargets = (builtins.filter isUnowned targets);
      noUnowned = (builtins.length unownedTargets) == 0;

    in
    if noUnowned then targets
    else throw (formatUnownedMsg unownedTargets);

  createReportEntry = target:
    {
      name = formatPath target;
      value = {
        inherit (target.deriv.meta) owners;
        path = target.deriv.outPath;
      };
    };

  buildReport = targets:
    let
      data = evaluate targets;
      jsonData = builtins.listToAttrs (map createReportEntry data);
      jsonEncoder = pkgs.formats.json { };
    in
    (jsonEncoder.generate "ownership-report.json" jsonData);

in
{
  inherit buildReport;
}
