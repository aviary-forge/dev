{ pkgs, lib, ... }:

let
  inherit (pkgs)
    runCommand
    nixfmt
    pre-commit
    writeShellApplication
    git
    ;
  rustfmt = pkgs.fenix.latest.rustfmt;

  # Generated config with every tool path pinned to the nix store.
  # No PATH assumptions — pre-commit's language: system hooks resolve
  # these absolute entry paths directly.
  pre-commit-config = runCommand "pre-commit-config.yaml" { } ''
        cat > "$out" << 'EOF'
    repos:
      - repo: local
        hooks:
          - id: nixfmt-check
            name: nixfmt
            entry: ${nixfmt}/bin/nixfmt --check
            language: system
            files: \.nix$
            exclude: '^rust/Cargo\.nix$'
            types: [file]
          - id: rustfmt-check
            name: rustfmt
            entry: ${rustfmt}/bin/rustfmt --check --edition 2021
            language: system
            files: \.rs$
            types: [file]
    EOF
  '';

  # The script that git invokes as .git/hooks/pre-commit.
  pre-commit-hook = writeShellApplication {
    name = "pre-commit-hook";
    runtimeInputs = [ pre-commit ];
    text = ''
      exec ${lib.getExe pre-commit} run \
        --config ${pre-commit-config} \
        --hook-stage pre-commit \
        "$@"
    '';
  };

  setup-pre-commit = writeShellApplication {
    name = "setup-pre-commit";
    runtimeInputs = [ git ];
    text = ''
      repo_root=$(git rev-parse --show-toplevel)
      hook_path="$repo_root/.git/hooks/pre-commit"
      target="${lib.getExe pre-commit-hook}"

      # Already pointing at the right thing — nothing to do.
      if [ -L "$hook_path" ] && [ "$(readlink "$hook_path")" = "$target" ]; then
        exit 0
      fi

      mkdir -p "$(dirname "$hook_path")"
      ln -sf "$target" "$hook_path"
      echo "[git-hooks] pre-commit hook installed" >&2
    '';
  };
in
{
  inherit setup-pre-commit pre-commit-hook;
}
