{
  dev ? (import ../../.. { }),
}:

let
  pkgs = dev.third_party.nixpkgs;
in
pkgs.mkShell {

  packages =
    (with pkgs.python314Packages; [
      uv
      python
      ruff
    ])
    ++ (with pkgs; [
      ty
      stdenv.cc.cc.lib
      zlib
      git-xet
      git-lfs
      git-lfs-transfer
    ]);

  shellHook =
    let
      libPath =
        with pkgs;
        lib.makeLibraryPath [
          stdenv.cc.cc.lib
          zlib
        ];
    in
    ''
      export LD_LIBRARY_PATH="${libPath}:/run/opengl-driver/lib:$LD_LIBRARY_PATH"
    '';
}
