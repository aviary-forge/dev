{
  pkgs,
  dev,
  members,
  ...
}:

let
  # Provider binaries from the daily snapshot.
  # https://github.com/nix-community/nixpkgs-terraform-providers-bin
  providers = import dev.third_party.nix.nixpkgs-terraform-providers-bin { };

  # OpenTofu (from unstable overlay) wrapped with the providers we use.
  # withPlugins sets up the plugin cache so `tofu init` works offline.
  tofu = pkgs.opentofu.withPlugins (p: [
    # Built-in providers from nixpkgs
    p.hashicorp_random
    p.hashicorp_null
    # Providers from the daily snapshot
    providers.providers.cloudflare.cloudflare
    providers.providers.hashicorp.aws
    providers.providers.tailscale.tailscale
  ]);

  # Allowlist, not denylist: a local .terraform/ or .direnv/ is gitignored but
  # present in the tree, and a stale .terraform/ makes `tofu init` reach for S3
  # backend credentials, which the sandbox can't provide. This nixpkgs has no
  # gitignore-aware cleanSource, and selecting positively needs no such help.
  tfSrc = pkgs.lib.cleanSourceWith {
    name = "terraform-src";
    src = ./.;
    filter =
      path: _:
      let
        name = baseNameOf path;
      in
      !(pkgs.lib.hasPrefix "." name) && pkgs.lib.hasSuffix ".tf" name;
  };
in
{
  inherit tofu;

  # Derivation that validates the terraform config in checkPhase.
  # Build this to check formatting and syntax in CI.
  validated = pkgs.stdenv.mkDerivation {
    name = "terraform-config-validated";
    src = tfSrc;
    dontBuild = true;
    doCheck = true;

    nativeBuildInputs = [ tofu ];

    # tofu init needs a writable directory, so copy source to $TMPDIR.
    checkPhase = ''
      set -euo pipefail

      cp -r "$src"/* .

      echo "=== tofu fmt ==="
      ${tofu}/bin/tofu fmt -check -diff .

      echo "=== tofu init ==="
      # -backend=false skips the S3 backend; providers come from the
      # Nix-managed plugin cache, so no network is needed.
      ${tofu}/bin/tofu init -backend=false

      echo "=== tofu validate ==="
      ${tofu}/bin/tofu validate
    '';

    installPhase = ''
      mkdir -p $out
      cp -r . $out/
    '';

    meta = {
      ci.skip = false;
      owners = with members; [ denbeigh ];
    };
  };

  # Hoist the validation drv so readTree's subtarget mechanism makes it
  # a CI target (plain attrs of an attrset node are invisible to
  # ci.targets discovery).
  meta.ci.targets = [ "validated" ];

  # Shell with tofu and tflint for interactive use. Exposed as a tree
  # child via the sibling shell.nix re-export.
  devShell = pkgs.mkShell {
    name = "tofu-shell";
    packages = [
      tofu
      pkgs.tflint
    ];

    shellHook = ''
      echo "OpenTofu $(tofu version -json | ${pkgs.jq}/bin/jq -r .opentofu_version)"
      echo "Providers: cloudflare, aws, tailscale"
      echo ""
      echo "Run 'tofu plan' to check changes, 'tofu apply' to apply."
    '';

    meta.owners = with members; [ denbeigh ];
  };
}
