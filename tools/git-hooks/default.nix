{ pkgs, lib, ... }:

let
  inherit (pkgs)
    runCommand
    makeWrapper
    nixfmt
    writeShellApplication
    git
    ;
  rustfmt = pkgs.fenix.latest.rustfmt;

  preCommitScript = ./pre-commit;

  pre-commit =
    runCommand "pre-commit-hook"
      {
        nativeBuildInputs = [ makeWrapper ];
        src = preCommitScript;
      }
      ''
        mkdir -p "$out/bin"
        install -m755 "$src" "$out/bin/pre-commit"
        wrapProgram "$out/bin/pre-commit" \
          --prefix PATH : ${
            lib.makeBinPath [
              nixfmt
              rustfmt
            ]
          }
      '';

  setup-pre-commit = writeShellApplication {
    name = "setup-pre-commit";
    runtimeInputs = [ git ];
    text = ''
      repo_root=$(git rev-parse --show-toplevel)
      git -C "$repo_root" config core.hooksPath "${pre-commit}/bin"
      echo "✓  pre-commit hook configured (core.hooksPath = ${pre-commit}/bin)"
    '';
  };
in
{
  inherit pre-commit setup-pre-commit;
}
