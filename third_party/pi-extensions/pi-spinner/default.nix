# @zenspc/pi-spinner — https://www.npmjs.com/package/@zenspc/pi-spinner
#
# Added by `pi-extensions-update add`; pinned via versions.json (see
# docs/pi-extensions-update-tool.md).
#
# TODO(human): document this package's runtime deps, lifecycle scripts
# (postinstall etc.) and any load-time quirks — the tool cannot infer them.
# pi-intercom/default.nix is the reference example of a fully documented
# package.
{
  dev,
  members,
  ...
}:
let
  versions = builtins.fromJSON (builtins.readFile ../versions.json);
in
dev.nix.mkPiPackage {
  pname = "pi-spinner";
  npmName = "@zenspc/pi-spinner";
  version = versions."@zenspc/pi-spinner";
  # sha256 of the npm tarball (`nix hash file --type sha256 --base64`)
  srcHash = "sha256-TaNUAKzocTrmRhOxYMHEKZAYHH44w41KtJ7hEGG7C74=";
  npmDepsHash = "sha256-BGtUcxnRv9Y9W+arGjgOWFnOgW3y3WyEs+/S2QSvQmU=";

  # The npm tarball ships no package-lock.json. The vendored lockfile was
  # generated with `npm install --package-lock-only --lockfile-version 3
  # --omit=peer`, so peers are recorded in the lock but not installed —
  # pi injects its own bundled copies at load time.
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  meta.owners = with members; [ denbeigh ];
}
