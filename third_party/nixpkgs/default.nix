# NOTE: this file is primarily the work of the TVL authors and carries the
# associated license thereof (MIT)

# This file imports the pinned nixpkgs sets and applies relevant
# modifications, such as our overlays.
#
# The actual source pinning happens via niv in //third_party/nix
#
# Note that the attribute exposed by this (third_party.nixpkgs) is
# "special" in that the fixpoint used as readTree's config parameter
# in //default.nix passes this attribute as the `pkgs` argument to all
# readTree derivations.

{
  dev ? { },
  externalArgs ? { },
  devOverlays ? true,
  localSystem ? externalArgs.localSystem or builtins.currentSystem,
  crossSystem ? externalArgs.crossSystem or localSystem,
  # additional overlays to be applied.
  # Useful when calling this file in a view exported from the monorepo.
  additionalOverlays ? [ ],
  ...
}:

let
  # Arguments passed to both the stable nixpkgs and the main, unstable one.
  # Includes everything but overlays which are only passed to unstable nixpkgs.
  commonNixpkgsArgs = {
    # allow users to inject their config into builds (e.g. to test CA derivations)
    config = (if externalArgs ? nixpkgsConfig then externalArgs.nixpkgsConfig else { }) // {
      allowUnfree = true;
      allowUnfreeRedistributable = true;
      allowBroken = true;
      # Forbids our meta.ci attribute
      # https://github.com/NixOS/nixpkgs/pull/191171#issuecomment-1260650771
      checkMeta = false;
      # *arr stack still depends on insecure .NET 6 packages
      # https://github.com/NixOS/nixpkgs/issues/360592
      permittedInsecurePackages = [
        "aspnetcore-runtime-6.0.36"
        "aspnetcore-runtime-wrapped-6.0.36"
        "dotnet-sdk-6.0.428"
        "dotnet-sdk-wrapped-6.0.428"
      ];
    };

    inherit localSystem crossSystem;
  };

  # import the nixos-unstable package set, or optionally use the
  # source (e.g. a path) specified by the `nixpkgsBisectPath`
  # argument. This is intended for use-cases where the monorepo is
  # bisected against nixpkgs to find the root cause of an issue in a
  # channel bump.
  nixpkgsSrc = externalArgs.nixpkgsBisectPath or dev.third_party.nix.nixpkgs;
  # Overlay to expose the nixpkgs commits we are using to other Nix code.
  commitsOverlay = _: _: {
    nixpkgsCommits = {
      stable = dev.third_party.nix.nixpkgs.rev;
      unstable = dev.third_party.nix.nixpkgs-unstable.dev;
    };
  };

  # TODO: this might need to move to home-manager config?
  # home-manager should get the nixpkgs source, but not the overlays...
  nixglOverlay =
    final: _:
    let
      isIntelX86Platform = final.system == "x86_64-linux";
    in
    {
      nixgl = import dev.third_party.nix.nixgl {
        pkgs = final;
        enable32bits = isIntelX86Platform;
        enableIntelX86Extensions = isIntelX86Platform;
      };
    };

  rustOverlay =
    final: prev:
    let
      pkgs = prev;

      crate2nixSrcRoot = dev.third_party.nix.crate2nix;
      crate2nixSrc = (import "${crate2nixSrcRoot}/crate2nix/default.nix");

      fenixSrc = (import "${dev.third_party.nix.fenix}/default.nix");
      fenix = (pkgs.callPackage fenixSrc { });
      # fenix = (pkgs.callPackage dev.third_party.nix.fenix) { };
      # fenix = pkgs.fenix;
      crate2nix = prev.callPackage crate2nixSrc {
        cargo = fenix.complete.toolchain;
      };
    in
    {
      inherit fenix;
      inherit crate2nix;
    };

  nixpkgsUnstable = import dev.third_party.nix.nixpkgs-unstable commonNixpkgsArgs;
  unstableOverlay = final: prev: {
    # Pull these from unstable to get newer versions than the stable channel
    inherit (nixpkgsUnstable)
      llama-cpp
      pi-coding-agent
      radarr
      sonarr
      prowlarr
      jackett
      ;
  };

  overridesOverlay =
    final: prev:
    let
      mkLlama = import ../overrides/llama-cpp.nix;
    in
    {
      llama-cpp-server = mkLlama {
        inherit (prev) llama-cpp fetchFromGitHub;
        cudaSupport = true;
        blasSupport = true;
        metalSupport = false;
      };

      llama-cpp-client = mkLlama {
        inherit (prev) llama-cpp fetchFromGitHub;
        cudaSupport = false;
        metalSupport = prev.stdenvNoCC.targetPlatform.isDarwin;
      };
    };

in
import nixpkgsSrc (
  commonNixpkgsArgs
  // {
    overlays = [
      commitsOverlay
      unstableOverlay
      nixglOverlay
      overridesOverlay
    ]
    ++ (
      if devOverlays then
        [
          # (import "${dev.third_party.nix.fenix}/overlay.nix")
          rustOverlay
        ]
      else
        [ ] ++ additionalOverlays
    );
  }
)
