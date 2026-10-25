{
  llama-cpp,
  fetchFromGitHub,
  fetchNpmDeps,
  version ? "11886",
  hash ? "sha256-t36+LlDygnMEsIcwMnlRnBbhmiQgwVE1jAbZN24cioA=",
  npmDepsHash ? "sha256-XLtEZsSFdk+2SyfXzBp8HQ2e27PQPpDCn1YjePU1/9w=",

  blasSupport ? true,
  cudaSupport ? true,
  rocmSupport ? false,
  metalSupport ? false,
}:

let
  src = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    tag = "b${version}";
    inherit hash;
    leaveDotGit = true;
    # TODO: keep? remove?
    postFetch = ''
      git -C "$out" rev-parse --short HEAD > $out/COMMIT
      find "$out" -name .git -print0 | xargs -0 rm -rf
    '';
  };
in
(llama-cpp.override {
  inherit
    cudaSupport
    rocmSupport
    metalSupport
    blasSupport
    ;
}).overrideAttrs
  (oldAttrs: {
    inherit version src npmDepsHash;

    # npmDeps for the version used in nixpkgs-unstable and this version are not
    # guaranteed to be the same.
    npmDeps = fetchNpmDeps {
      name = "llama-cpp-${version}-npm-deps";
      inherit src;
      patches = [ ];
      inherit npmDepsHash;
      hash = npmDepsHash;
      preBuild = ''
        pushd tools/ui
      '';
    };
    # Enable native CPU optimizations (AVX, AVX2, etc.)
    cmakeFlags = (oldAttrs.cmakeFlags or [ ]) ++ [
      "-DGGML_NATIVE=ON"
    ];
    # Disable Nix's march=native stripping
    preConfigure = ''
      export NIX_ENFORCE_NO_NATIVE=0
      ${oldAttrs.preConfigure or ""}
    '';
    meta = {
      badPlatforms = [ ];
    };

    # Synced from nixpkgs master for this version. When bumping the llama.cpp
    # tag, re-check upstream's list — if any excluded test is a FIXTURES_SETUP
    # with surviving dependents (e.g. test-download-model), ctest 4.4.4's
    # --exclude-from-file silently re-adds it and the dependent tests go
    # Not Run, so the list must stay complete w.r.t. the fixture graph or
    # exclusions fail with zero diagnostics. (A --exclude-regex workaround
    # avoids the re-add but is not upstream-idiomatic; upstream's list at
    # master has the fixture graph complete, so plain disabledTests works.)
    # Upstream file:
    # https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/ll/llama-cpp/package.nix
    disabledTests = [
      "test-tokenizers-ggml-vocabs"
      "test-download-model"
      "test-arg-parser"
      "test-thread-safety"
      "test-llama-context-model"
    ];
  })
