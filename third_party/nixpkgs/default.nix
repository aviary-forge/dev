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
  # the niv pin set (//third_party/nix). Explicit so this file can be
  # evaluated outside the readTree fixpoint (e.g. as the global <nixpkgs>).
  pins ? import ../nix { },
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
    config = (externalArgs.nixpkgsConfig or { }) // {
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
  nixpkgsSrc = externalArgs.nixpkgsBisectPath or pins.nixpkgs;
  # Overlay to expose the nixpkgs commits we are using to other Nix code.
  commitsOverlay = _: _: {
    nixpkgsCommits = {
      stable = pins.nixpkgs.rev;
      unstable = pins.nixpkgs-unstable.rev;
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
      nixgl = import pins.nixgl {
        pkgs = final;
        enable32bits = isIntelX86Platform;
        enableIntelX86Extensions = isIntelX86Platform;
      };
    };

  rustOverlay =
    final: prev:
    let
      fenixSrc = import "${pins.fenix}/default.nix";
      fenix = prev.callPackage fenixSrc { };
      craneLib = prev.callPackage "${pins.crane}/lib" { };
    in
    {
      inherit fenix;
      inherit craneLib;
    };

  nixpkgsUnstable = import pins.nixpkgs-unstable commonNixpkgsArgs;
  unstableOverlay = final: prev: {
    # Pull these from unstable to get newer versions than the stable channel
    inherit (nixpkgsUnstable)
      curl-impersonate
      llama-cpp
      opentofu
      pi-coding-agent
      radarr
      sonarr
      prowlarr
      jackett
      ;
  };

  # curl-cffi 0.14.0's test suite breaks against the newer curl-impersonate
  # in the pins: the three test_verify tests expect the old CA-failure error
  # wording ("SSL certificate problem"), but the newer backend reports the
  # hostname mismatch first (the test cert only covers "localhost" while the
  # test server binds 127.0.0.1), and test_delete_cookies fails on cookie
  # store behaviour. nixpkgs skips the same four tests since 76f3d156.
  # Self-removes once the pin moves past 0.14.0.
  curlCffiTestSkipOverlay = final: prev: {
    # override the interpreter, not python3Packages.overrideScope —
    # the latter recurses against python3Packages = python313.pkgs.
    python313 = prev.python313.override {
      # NOTE: don't guard on pysuper.curl-cffi.version here — forcing
      # anything off pysuper inside packageOverrides reaches back into the
      # outer scope's python3Packages and recurses the fixpoint.
      packageOverrides = _: pysuper: {
        curl-cffi = pysuper.curl-cffi.overrideAttrs (old: {
          disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
            "tests/unittest/test_async_session.py::test_verify"
            "tests/unittest/test_curl.py::test_verify"
            "tests/unittest/test_requests.py::test_verify"
            "tests/unittest/test_requests.py::test_delete_cookies"
          ];
        });
      };
    };
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
      curlCffiTestSkipOverlay
      overridesOverlay
    ]
    # devOverlays controls the repo-specific dev overlays (rust/fenix).
    ++ (
      if devOverlays then
        [
          # (import "${pins.fenix}/overlay.nix")
          rustOverlay
        ]
      else
        [ ]
    )
    # additionalOverlays is always applied, on top of everything above.
    ++ additionalOverlays;
  }
)
