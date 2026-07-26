# Build inputs for the ci-orchestrator crate.
#
# We don't directly need openssl, but the workspace shares a dependency
# closure with gcroot-manager (which uses git2 → openssl-sys). Crane's
# per-member buildPackage doesn't inherit the merged workspace inputs,
# so we must declare them here too.
{ pkgs, ... }:

{
  nativeBuildInputs = with pkgs; [
    pkg-config
  ];

  buildInputs = with pkgs; [
    openssl
  ];
}
