{ dev, pkgs, ... }:

let
  # NOTE: this currently requires us to copy the monorepo to the store, but the
  # cost is still low enough that i'm not too fussed about that.
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
        ${system}/bin/switch-to-configuration switch
      '';
    };

  mkBaseModule = pkgs': {
    nixpkgs.pkgs = pkgs';

    # ad-hoc tooling (nix-shell -p, nix-build '<nixpkgs>') resolves to the
    # monorepo's pinned, overlaid nixpkgs — the same set the system is built
    # from. Setting nixPath here replaces the channel-derived defaults.
    nix.nixPath = [
      "nixpkgs=${dev.path + "/third_party/nixpkgs/global.nix"}"
    ];

    # no channels: the pinned nixpkgs above is the only package set this
    # system should see
    nix.channel.enable = false;
  };

in
{
  inherit mkBaseModule;

  # eval: produce a NixOS system target.
  #
  # Takes an attrset with:
  #
  #   configuration: the machine's configuration module.
  #   system:        the machine's platform (e.g. "x86_64-linux"), declared
  #                  as data. Exposed cheaply — reading `.system` on the
  #                  target does NOT force the module fixpoint, which is
  #                  what lets CI's drvmap filter out foreign-system
  #                  targets without cross-evaluating them.
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
      # Cross-eval: when forcing a machine fixpoint whose platform differs
      # from the eval host, re-import the pinned nixpkgs for the machine's
      # platform. Otherwise every `pkgs.stdenv.hostPlatform` guard in
      # modules/ sees the *host's* platform (e.g. darwin-only modules get
      # imported into a NixOS machine, setting launchd-only options), and
      # the derived-system check below fails. Pure evaluation only — the
      # derivations still build on/for the target platform.
      targetPkgs =
        if system == pkgs.system then
          pkgs
        else
          import (dev.path + "/third_party/nixpkgs") { localSystem = system; };

      nixosEval = dev.third_party.nixos {
        configuration =
          { ... }:
          {
            imports = [
              (mkBaseModule targetPkgs)
              configuration
            ];
          };

        # NB: specialArgs.pkgs shadows the module system's pkgs resolution;
        # that's intentional (see the nixpkgs specialArgs warning) — modules
        # must see the same pkgs set that nixpkgs.pkgs pins.
        specialArgs = {
          inherit dev;
          pkgs = targetPkgs;
        };
      };

      # Forces the fixpoint; only read where the eval happens anyway.
      derivedSystem = nixosEval.system.system;

      checkedDrvPath =
        if derivedSystem != system then
          throw "nixos machine declares system '${system}' but evaluates as '${derivedSystem}' — fix the declaration"
        else
          nixosEval.system.drvPath;

    in
    {
      inherit (nixosEval) vm;
      inherit system meta;
      drvPath = checkedDrvPath;
      outPath = nixosEval.system.outPath;
      activate = activateSystem nixosEval.system;
      __devAttrType = "nixos-system";
    };
}
