{
  llama-cpp,
  fetchFromGitHub,
  version ? "9159",
  hash ? "sha256-y69ZmVFxo7bQvLTT6/GWwkb5j4Ll8eXSVXFpfXVkvyg=",
  npmDepsHash ? "sha256-WaEePrEZ7O/7deP2KJhe0AwiSKYA8HOqETmMHUkmBe0=",

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
  })
