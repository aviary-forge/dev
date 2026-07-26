{
  dev,
  config,
  pkgs,
  lib,
  ...
}:

# NOTE: This module is currently non-functional pending terraform config migration.
# TODO(denbeigh): migrate terraform configs from ~/.dotfiles/terraform/ into
# this monorepo, update third_party/terraform to include needed providers
# (cloudflare, digitalocean, aws, tailscale), and fix the apply-terraform script.
let
  # tf-providers = dev.third_party.terraform.providers-src;
  # tf-packages = dev.third_party.terraform;

  applyTerraform = pkgs.writeShellScriptBin "apply-terraform" ''
    echo "terraform module: apply-terraform not yet implemented in monorepo" >&2
    echo "TODO: migrate terraform configs from ~/.dotfiles/terraform/" >&2
    exit 1
  '';
in

{
  age.secrets.terraform = {
    file = dev.secrets."terraform.age";
  };

  environment.systemPackages = [ applyTerraform ];
}
