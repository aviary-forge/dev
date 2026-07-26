{ dev, pkgs, ... }:

let
  activateSystem =
    system:
    pkgs.writeShellApplication {
      name = "activate";

      text = ''
        if [[ "$EUID" -ne "0" ]]
        then
          echo "system must be activated as root" >&2
          exit 1
        fi

        nix-env -p /nix/var/nix/profiles/system --set ${system}
        ${system}/sw/bin/darwin-rebuild activate
      '';
    };

in
rec {
  baseModule = _: {
    nixpkgs.pkgs = dev.third_party.nixpkgs;

    # allow us to skip the global configuration check, similar to building with
    # flakes
    system.checks.verifyNixPath = false;
  };

  # eval: produce a nix-darwin system target.
  #
  # Accepts either a configuration function directly (legacy) or an
  # attrset with `configuration` and optional `meta` (preferred).
  # `meta.owners` is threaded through to the drvmap for CI ownership.
  eval =
    arg:
    let
      configuration = if builtins.isFunction arg then arg else arg.configuration;
      meta = if builtins.isFunction arg then { } else arg.meta or { };

      darwinEval = dev.third_party.darwin.eval {
        configuration = { ... }: {
          imports = [
            baseModule
            configuration
          ];
        };

        specialArgs = { inherit dev pkgs; };
      };
    in
    {
      inherit (darwinEval) system;
      inherit (darwinEval.toplevel) outPath drvPath;
      inherit meta;
      activate = activateSystem darwinEval.toplevel;
      __devAttrType = "darwin-system";
    };
}
