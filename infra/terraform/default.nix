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
    providers.providers.digitalocean.digitalocean
    providers.providers.hashicorp.aws
    providers.providers.tailscale.tailscale
  ]);

  # The .tf source files to validate (exclude Nix and git files).
  tfSrc = pkgs.lib.cleanSourceWith {
    name = "terraform-src";
    src = ./.;
    filter =
      path: type:
      let
        base = baseNameOf path;
      in
      base != "default.nix" && base != ".gitignore" && base != "secrets.env";
  };
in
{
  packages = {
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
        # -backend=false skips S3 backend config (not needed for validation).
        # Providers are resolved from the Nix-managed plugin cache.
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
  };

  # Shell with tofu and tflint for interactive use.
  devShell = pkgs.mkShell {
    name = "tofu-shell";
    packages = [
      tofu
      pkgs.tflint
    ];

    shellHook = ''
      echo "OpenTofu $(tofu version -json | ${pkgs.jq}/bin/jq -r .opentofu_version)"
      echo "Providers: cloudflare, digitalocean, aws, tailscale"
      echo ""
      echo "Run 'tofu plan' to check changes, 'tofu apply' to apply."
    '';
  };
}
