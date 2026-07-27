{
  dev,
  pkgs,
  members,
  ...
}:

let
  nodeModules = dev.third_party.pnpm2nix-nzbr.mkPnpmPackage {
    src = ./.;
    inherit (pkgs) pnpm;
    scriptFull = "true"; # no build — we only want node_modules
    distDir = "node_modules";
    distDirIsOut = false; # put node_modules under $out/node_modules
    pnpmLockYaml = ./pnpm-lock.yaml;
  };
in
dev.nix.buildCloudflareWorker {
  name = "shortlink";
  src = ./.;
  inherit nodeModules;

  meta.owners = with members; [ denbeigh ];
}
