{ dev, pkgs, ... }:

rec {
  baseModule = { ... }: {
    nixpkgs.pkgs = dev.third_party.nixpkgs;
  };

  nixosFor = configuration:
    (dev.third_party.nixos
      {
        configuration = { ... }: {
          imports = [
            baseModule
            configuration
          ];
        };

        specialArgs = {
          inherit dev;
        };
      });

  findSystem = hostname:
    (pkgs.lib.findFirst
      (system: system.config.networking.hostName == hostname)
      (throw "i do not know about ${hostname}")
      (map nixosFor dev.systems.configs.all));

  rebuild-system = rebuildSystemWith (
    # faster than making a full copy of the monorepo to the story (NOTE: wouldn't
    # function with flakes)
    builtins.toString dev.path.origSrc);

  rebuildSystemWith = repoPath: pkgs.writeShellScriptBin "rebuild-system" ''
    set -eu

    if [[ $EUID -ne 0 ]]; then
      echo "root is required to rebuild system" >&2
      exit 1
    fi

    echo "Rebuilding system $HOSTNAME" >&2
    system="$(${pkgs.nix}/bin/nix-build -E "((import ${repoPath} {}).nix.nixos.findSystem \"$HOSTNAME\").system" --no-out-link --show-trace)"

    ${pkgs.nix}/bin/nix-env -p /nix/var/nix/profiles/system --set "$system"
    "$system/bin/switch-to-configuration" switch
  '';
}
