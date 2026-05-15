{ llama-cpp
, fetchFromGitHub
, version ? "9159"
, hash ? "sha256-y69ZmVFxo7bQvLTT6/GWwkb5j4Ll8eXSVXFpfXVkvyg="
, ...
}:

let
  src = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    tag = "b${version}";
    inherit hash;
    leaveDotGit = true;
    postFetch = ''
      git -C "$out" rev-parse --short HEAD > $out/COMMIT
      find "$out" -name .git -print0 | xargs -0 rm -rf
    '';
  };
in
(llama-cpp.override {
  cudaSupport = true;
  rocmSupport = false;
  metalSupport = false;
  # Enable BLAS for optimized CPU layer performance (OpenBLAS)
  blasSupport = true;
}).overrideAttrs
  (oldAttrs: rec {
    inherit version src;
    # Enable native CPU optimizations (AVX, AVX2, etc.)
    cmakeFlags = (oldAttrs.cmakeFlags or [ ]) ++ [
      "-DGGML_NATIVE=ON"
    ];
    # Disable Nix's march=native stripping
    preConfigure = ''
      export NIX_ENFORCE_NO_NATIVE=0
      ${oldAttrs.preConfigure or ""}
    '';
  })

