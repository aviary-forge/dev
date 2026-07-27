{ pkgs, ... }:

# Build a Cloudflare Worker bundle from TypeScript source.
#
# Takes source, an entry point, and a Nix-built node_modules path,
# produces a deterministic bundle via esbuild.
#
# The consumer provides nodeModules via whatever npm-in-Nix strategy
# they prefer (yarn2nix, js2nix, dream2nix, etc.).
{
  name, # derivation name (e.g. "my-bot-worker")
  src, # source tree with package.json, tsconfig.json, src/
  entryPoint ? "src/index.ts",
  nodeModules, # Nix-built node_modules derivation
  skipTypecheck ? false,
  meta ? { },
}:

pkgs.stdenvNoCC.mkDerivation {
  name = "${name}-cf-worker-bundle";
  inherit src meta;

  nativeBuildInputs = [
    pkgs.esbuild
    pkgs.nodejs
  ];

  doCheck = !skipTypecheck;

  configurePhase = ''
    ln -sf ${nodeModules}/node_modules ./node_modules
  '';

  buildPhase = ''
    ${pkgs.esbuild}/bin/esbuild --bundle \
      --format=esm \
      --target=es2024 \
      --platform=browser \
      --conditions=workerd,worker,browser \
      --external:__STATIC_CONTENT_MANIFEST \
      --outfile=$out/index.js \
      --sourcemap \
      ${entryPoint}
  '';

  checkPhase =
    if skipTypecheck then
      ""
    else
      ''
        ${nodeModules}/node_modules/.bin/tsc --noEmit
      '';

  installPhase = ''
    # buildPhase already wrote index.js and index.js.map into $out.
    # No additional copying needed.
    :
  '';
}
