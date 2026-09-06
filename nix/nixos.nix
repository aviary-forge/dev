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
  };

in

{
  inherit baseModule;

  # eval: produce a NixOS system target.
  #
  # Accepts either a configuration function directly (legacy) or an
  # attrset with `configuration` and optional `meta` (preferred).
  # `meta.owners` is threaded through to the drvmap for CI ownership.
  eval =
    arg:
    let
      configuration = if builtins.isFunction arg then arg else arg.configuration;
      meta = if builtins.isFunction arg then { } else arg.meta or { };

      nixosEval = dev.third_party.nixos {
        configuration =
          { ... }:
          {
            imports = [
              baseModule
              configuration
            ];
          };

        specialArgs = {
          inherit dev pkgs;
        };
      };

    in
    {
      inherit (nixosEval) vm;
      system = nixosEval.system.system;
      inherit (nixosEval.system) outPath drvPath;
      inherit meta;
      activate = activateSystem nixosEval.system;
      __devAttrType = "nixos-system";
    };
}
