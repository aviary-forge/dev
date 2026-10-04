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
    # Pull these from unstable to track newer versions than the stable channel.
    # On the current pins they are all also the stable version, so this list is
    # doing nothing but carrying unstable's glibc into their closures — re-check
    # it whenever nixpkgs is bumped and drop whatever stops being a real upgrade.
    inherit (nixpkgsUnstable)
      llama-cpp
      opentofu
      pi-coding-agent
      radarr
      sonarr
      prowlarr
      jackett
      ;

    # curl-impersonate is upgraded for real (1.5.6 -> 2.1.1), and is the one
    # that can't just be inherited: inherited outputs link unstable's glibc
    # (2.44) and fail to dlopen from a stable (2.42) process, e.g. curl-cffi
    # dying in pythonImportsCheck with "GLIBC_2.43 not found". 2.x vendors its
    # own TLS/zlib deps, so toolchain and glibc are all that need to match.
    curl-impersonate = final.callPackage (
      pins.nixpkgs-unstable + "/pkgs/by-name/cu/curl-impersonate/package.nix"
    ) { };
  };

  # curl-cffi 0.14.0 (the stable pin's version) fails against
  # curl-impersonate 2.x: three test_verify cases assert on the wording of the
  # TLS failure, and 2.x reports the hostname mismatch before the CA problem;
  # test_delete_cookies asserts cookie-jar behaviour that changed.
  #
  # These run on every build — python package checks live in distPhase, not
  # behind doCheck — but only surfaced once the ABI above was fixed, since the
  # glibc break killed pythonImportsCheck before pytest was reached.
  #
  # Redundant once the stable pin carries curl-cffi >= 0.16.0: upstream fixed
  # the assertions in the curl-cffi source, not in nixpkgs.
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

      # Wrap an mkShell-family constructor so its results carry the CI
      # discovery marker.
      mkStampedShell =
        mkShell': args:
        (mkShell' args).overrideAttrs (old: {
          passthru = old.passthru or { } // {
            __devAttrType = "shell";
          };
        });
    in
    {
      # Stamp shells so we can enumerate them for CI.
      mkShell = args: mkStampedShell prev.mkShell args;
      mkShellNoCC = args: mkStampedShell prev.mkShellNoCC args;

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

  # pre-commit's check suite needs dotnet-sdk, which must be bootstrapped
  # from source on darwin (pain), and is only necessary for testing.
  #   doCheck = false     — drops the check inputs (incl. dotnet-sdk)
  #   preCheck = ""       — package.nix exports DOTNET_ROOT unconditionally;
  #                         the string context would keep dotnet-sdk as a
  #                         drv input
  #   dontUsePytestCheck  — this pin's `identify` propagates pytestCheckHook
  #                         from `dependencies` (upstream bug), which
  #                         registers pytestCheckPhase in preDistPhases
  #                         regardless of doCheck; pre-commit's
  #                         pytestFlags = [ "--forked" ] then fails without
  #                         pytest-forked installed
  preCommitNoChecksOverlay = final: prev: {
    pre-commit = prev.pre-commit.overridePythonAttrs {
      doCheck = false;
      preCheck = "";
      dontUsePytestCheck = true;
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
      preCommitNoChecksOverlay
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
