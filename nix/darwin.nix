{ dev, pkgs, ... }:

let
  activateSystem =
    system:
    pkgs.writeShellApplication {
      name = "activate";

      runtimeInputs = [ pkgs.nix ];

      text = ''
        if [[ "$EUID" -ne "0" ]]
        then
          echo "system must be activated as root" >&2
          exit 1
        fi

        # sudo(8) on macOS preserves $HOME; the invoking user's home isn't
        # owned by root, which makes Nix warn and fall back to the passwd
        # entry. Match darwin-rebuild's behaviour and set it up front.
        HOME=~root
        export HOME

        nix-env -p /nix/var/nix/profiles/system --set ${system}
        ${system}/sw/bin/darwin-rebuild activate
      '';
    };

in
rec {
  baseModule = _: {
    nixpkgs.pkgs = dev.third_party.nixpkgs;

    # ad-hoc tooling (nix-shell -p, nix-build '<nixpkgs>') resolves to the
    # monorepo's pinned, overlaid nixpkgs — the same set the system is built
    # from. Setting nixPath here replaces the channel-derived defaults.
    nix.nixPath = [
      "nixpkgs=${dev.path + "/third_party/nixpkgs/global.nix"}"
    ];

    # no channels: the pinned nixpkgs above is the only package set this
    # system should see
    nix.channel.enable = false;

    # allow us to skip the global configuration check, similar to building with
    # flakes
    system.checks.verifyNixPath = false;
  };

  # eval: produce a nix-darwin system target.
  #
  # Takes an attrset with:
  #
  #   configuration: the machine's configuration module.
  #   system:        the machine's platform (e.g. "aarch64-darwin"), declared
  #                  as data. Exposed cheaply — reading `.system` on the
  #                  target does NOT force the module fixpoint, which is
  #                  what lets CI's drvmap filter out foreign-system
  #                  targets without cross-evaluating them. (It used to be
  #                  the toplevel derivation itself, which leaked a store
  #                  path into the drvmap's system field.)
  #   meta:          optional metadata, threaded through to the drvmap
  #                  for CI ownership.
  #
  # Platform declaration vs. derivation: when the fixpoint IS forced
  # (same-platform builds), the derived system is checked against the
  # declaration, so a typo'd declaration fails loudly instead of silently
  # mislabelling the target.
  eval =
    {
      configuration,
      system,
      meta ? { },
    }:
    let
      darwinEval = dev.third_party.darwin.eval {
        configuration = { ... }: {
          imports = [
            baseModule
            configuration
          ];
        };

        specialArgs = { inherit dev pkgs; };
      };

      # Forces the fixpoint; only read where the eval happens anyway.
      derivedSystem = darwinEval.toplevel.system;

      checkedDrvPath =
        if derivedSystem != system then
          throw "darwin machine declares system '${system}' but evaluates as '${derivedSystem}' — fix the declaration"
        else
          darwinEval.toplevel.drvPath;

    in
    {
      inherit system meta;
      inherit (darwinEval) toplevel;
      drvPath = checkedDrvPath;
      outPath = darwinEval.toplevel.outPath;
      activate = activateSystem darwinEval.toplevel;
      __devAttrType = "darwin-system";
    };
}
