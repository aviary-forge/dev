{
  llama-cpp,
  fetchFromGitHub,
  version ? "9850",
  hash ? "sha256-3+eHH0Ql6blNU8hqufdnUBF5BBI5qtlHwzZisvIDRow=",
  npmDepsHash ? "sha256-X1DZgmhS/zHTqDT5zq0kywwntthcJ9vRXeqyO3zz6UU=",

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
