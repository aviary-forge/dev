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
    && !(target.meta.broken or false)
    # filter so we skip targets explicitly opted out of CI
    && !(target.meta.ci.skip or false);
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
      # cleanSourceFilter handles .git/result/hidden files; this additionally
      # keeps build artifacts and tool state out of the store copy. Without
      # this, any system referencing dev.path (nixos activation copies, the
      # NIX_PATH <nixpkgs> shim) drags gigabytes of _build/ and target/ into
      # the store. secrets/ handling is delegated to its .gitignore.
      filter =
        name: type:
        self.third_party.nixpkgs.lib.cleanSourceFilter name type
        && !builtins.elem (baseNameOf name) [
          "_build"
          "target"
          "node_modules"
          ".opencode"
          ".claude"
        ];
    };

    ci =
      let
        mkSystemDiscovery =
          isSystemPredicate:
          let
            inherit (builtins) concatStringsSep filter listToAttrs;

            targets = readTree.gather isSystemPredicate self;
            byPath =
              let
                paths = map (
                  t:
                  let
                    p = concatStringsSep "." t.__readTree;
                  in
                  if p != "" then
                    {
                      name = p;
                      value = t;
                    }
                  else
                    null
                ) targets;
              in
              listToAttrs (filter (x: x != null) paths);
          in
          {
            inherit targets byPath;
          };

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

        # Grouped system discovery for CI pipeline generation.
        # Use `ci.systems.nixos.targets` etc. to get all NixOS/darwin/home-manager configs.
        # Individual configs are at `systems.configs.<name>` (readTree natural path).
        systems = {
          nixos = mkSystemDiscovery (
            target: target ? __devAttrType && target.__devAttrType == "nixos-system"
          );
          darwin = mkSystemDiscovery (
            target: target ? __devAttrType && target.__devAttrType == "darwin-system"
          );
          "home-manager" = mkSystemDiscovery (
            target: target ? __devAttrType && target.__devAttrType == "home-manager-system"
          );
        };

        # Static-analysis / meta checks (formatting, linting, etc.).
        # Use `ci.checks.formatting.targets` to get all formatting-check targets.
        # These are lightweight checks that gate merges but aren't real builds.
        checks = {
          formatting = mkSystemDiscovery (
            target: target ? __devAttrType && target.__devAttrType == "formatting-check"
          );
        };
      };
  }
)
