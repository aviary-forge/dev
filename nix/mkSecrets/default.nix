# Expose secrets as part of the tree, making it possible to validate
# their paths at eval time.
#
# Note that encrypted secrets end up in the Nix store, but this is
# fine since they're publicly available anyways.
{ dev, pkgs, ... }:

let
  buildSecret = path: name: value:
    let
      formatInvalidMsg = keys:
        let
          keyList = [ "" ] ++ keys;
          keyMsg = pkgs.lib.concatStringsSep "\n - " keyList;
        in
        "The following public keys are invalid:\n${keyMsg}";

      invalidPublicKeys =
        builtins.filter (key: (!pkgs.lib.hasPrefix "ssh-" key))
          value.publicKeys;

      path_ =
        if (builtins.length invalidPublicKeys > 0)
        then throw (formatInvalidMsg invalidPublicKeys)
        else path;

    in
    # NOTE: everything above is only for validation of the public keys given
      # in the value, which aren't actually used otherwise (they're only used at
      # encryption and decryption time, and pasting the wrong value here could
      # be a sad time in future.
    "${path_}/${name}";
in
path: secrets:
dev.nix.readTree.drvTargets
  (builtins.mapAttrs (buildSecret path) secrets)
