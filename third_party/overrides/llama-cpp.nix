{
  llama-cpp,
  fetchFromGitHub,
  version ? "10516",
  hash ? "sha256-Dm3mXDE/JLwBFfeyqH7bg/K4C2YfRfuGnj7KTnabcTw=",
  npmDepsHash ? "sha256-2Q7XhaLAArmviOLdQsNbYTfdyDE5pW9lR26cRHEVl9k=",

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
