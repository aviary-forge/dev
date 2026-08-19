{
  dev ? import ../.. { },
}:

# nix-repl> third_party.nixpkgs.fenix.stable.
# third_party.nixpkgs.fenix.stable.cargo
# third_party.nixpkgs.fenix.stable.clippy
# third_party.nixpkgs.fenix.stable.clippy-preview
# third_party.nixpkgs.fenix.stable.clippy-preview-unwrapped
# third_party.nixpkgs.fenix.stable.clippy-unwrapped
# third_party.nixpkgs.fenix.stable.completeToolchain
# third_party.nixpkgs.fenix.stable.defaultToolchain
# third_party.nixpkgs.fenix.stable.llvm-bitcode-linker
# third_party.nixpkgs.fenix.stable.llvm-bitcode-linker-preview
# third_party.nixpkgs.fenix.stable.llvm-tools
# third_party.nixpkgs.fenix.stable.llvm-tools-preview
# third_party.nixpkgs.fenix.stable.manifest
# third_party.nixpkgs.fenix.stable.minimalToolchain
# third_party.nixpkgs.fenix.stable.reproducible-artifacts
# third_party.nixpkgs.fenix.stable.rust
# third_party.nixpkgs.fenix.stable.rust-analysis
# third_party.nixpkgs.fenix.stable.rust-analyzer
# third_party.nixpkgs.fenix.stable.rust-analyzer-preview
# third_party.nixpkgs.fenix.stable.rust-docs
# third_party.nixpkgs.fenix.stable.rust-src
# third_party.nixpkgs.fenix.stable.rust-std
# third_party.nixpkgs.fenix.stable.rustc
# third_party.nixpkgs.fenix.stable.rustc-dev
# third_party.nixpkgs.fenix.stable.rustc-docs
# third_party.nixpkgs.fenix.stable.rustc-unwrapped
# third_party.nixpkgs.fenix.stable.rustfmt
# third_party.nixpkgs.fenix.stable.rustfmt-preview
# third_party.nixpkgs.fenix.stable.toolchain
# third_party.nixpkgs.fenix.stable.withComponents

let
  pkgs = dev.third_party.nixpkgs;
  rustPkgs = with pkgs.fenix.latest; [
    toolchain
    clippy-preview
    rustfmt-preview
  ];
  stdPkgs = with pkgs; [
    openssl.dev
    pkg-config
  ];
in
pkgs.mkShell {
  packages = rustPkgs ++ stdPkgs;
}
