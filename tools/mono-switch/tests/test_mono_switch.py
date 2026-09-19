"""Tests for mono-switch's pure logic (no nix, no sudo, no network)."""

import os
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from mono_switch import (
    MonoSwitchError,
    build_activate,
    is_monorepo,
    parse_args,
    parse_target_file,
    resolve_root,
    resolve_target,
    write_target_file,
)


def make_repo(path: Path) -> Path:
    """Lay out the two files is_monorepo keys on."""
    (path / "nix" / "readTree").mkdir(parents=True)
    (path / "nix" / "readTree" / "default.nix").touch()
    (path / "default.nix").touch()
    return path


@pytest.fixture
def fake_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Point ~/dev/dev at a valid fake checkout under tmp_path."""
    monkeypatch.setenv("HOME", str(tmp_path))
    return make_repo(tmp_path / "dev" / "dev")


@pytest.fixture
def no_git(monkeypatch: pytest.MonkeyPatch) -> None:
    """Make the git probe fail, as when cwd is not a repo."""
    monkeypatch.setattr(
        subprocess,
        "run",
        lambda *a, **k: SimpleNamespace(returncode=1, stdout=""),
    )


def fake_git(monkeypatch: pytest.MonkeyPatch, repo: Path) -> None:
    monkeypatch.setattr(
        subprocess,
        "run",
        lambda *a, **k: SimpleNamespace(returncode=0, stdout=f"{repo}\n"),
    )


# --- is_monorepo ---


def test_is_monorepo_matches_layout(tmp_path: Path):
    assert is_monorepo(make_repo(tmp_path / "r"))
    assert not is_monorepo(tmp_path / "other")


# --- parse_target_file ---


def test_parse_modern_cache(tmp_path: Path):
    f = tmp_path / "target"
    f.write_text("root=/some/repo\ntarget=systems.configs.aviary\n")
    assert parse_target_file(f) == {
        "root": "/some/repo",
        "target": "systems.configs.aviary",
    }


def test_parse_legacy_bare_line(tmp_path: Path):
    f = tmp_path / "target"
    f.write_text("systems.configs.aviary\n")
    assert parse_target_file(f) == {"target": "systems.configs.aviary"}


def test_parse_skips_comments_and_blanks(tmp_path: Path):
    f = tmp_path / "target"
    f.write_text("# a comment\n\ntarget=t\n")
    assert parse_target_file(f) == {"target": "t"}


def test_parse_unknown_keyed_line_errors(tmp_path: Path):
    # A mangled `foo=bar` line must not silently become the target.
    f = tmp_path / "target"
    f.write_text("target=ok\nfoo=bar\n")
    with pytest.raises(MonoSwitchError, match="foo=bar"):
        parse_target_file(f)


def test_parse_read_error(tmp_path: Path):
    with pytest.raises(MonoSwitchError, match="could not read"):
        parse_target_file(tmp_path / "does-not-exist")


# --- parse_args ---


def test_parse_args_defaults():
    assert parse_args([]) == (None, False)


def test_parse_args_target_forms():
    assert parse_args(["-t", "x"]) == ("x", False)
    assert parse_args(["--target", "x"]) == ("x", False)
    assert parse_args(["--target=x"]) == ("x", False)


def test_parse_args_build_only():
    assert parse_args(["-b"]) == (None, True)
    assert parse_args(["--build-only"]) == (None, True)


def test_parse_args_missing_value_exits(capsys: pytest.CaptureFixture):
    with pytest.raises(SystemExit):
        parse_args(["-t"])
    assert "argument" in capsys.readouterr().err


def test_parse_args_help_exits_zero(capsys: pytest.CaptureFixture):
    with pytest.raises(SystemExit) as exc_info:
        parse_args(["--help"])
    assert exc_info.value.code == 0
    assert "resolution order" in capsys.readouterr().out


# --- resolve_root ---


def test_resolve_root_env_wins(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, fake_home: Path):
    repo = make_repo(tmp_path / "elsewhere")
    monkeypatch.setenv("MONOREPO_ROOT", str(repo))
    fake_git(monkeypatch, tmp_path / "git-repo")  # should be ignored
    assert resolve_root(str(fake_home)) == (repo, "$MONOREPO_ROOT")


def test_resolve_root_env_invalid_errors(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, no_git: None
):
    monkeypatch.setenv("MONOREPO_ROOT", str(tmp_path / "not-a-repo"))
    with pytest.raises(MonoSwitchError, match="not a monorepo checkout"):
        resolve_root(None)


def test_resolve_root_git_first(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, fake_home: Path):
    git_repo = make_repo(tmp_path / "git-repo")
    fake_git(monkeypatch, git_repo)
    assert resolve_root(str(fake_home)) == (git_repo, "git (cwd)")


def test_resolve_root_cache_beats_homedir(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, fake_home: Path, no_git: None
):
    cached = make_repo(tmp_path / "cached")
    assert resolve_root(str(cached)) == (cached, "cache")


def test_resolve_root_homedir_fallback(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, fake_home: Path, no_git: None
):
    assert resolve_root(None) == (fake_home, "~/dev/dev")


def test_resolve_root_homedir_order_dev_dev_before_dev(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, no_git: None
):
    # Both home candidates exist; ~/dev/dev must win.
    monkeypatch.setenv("HOME", str(tmp_path))
    make_repo(tmp_path / "dev" / "dev")
    make_repo(tmp_path / "dev")
    assert resolve_root(None)[1] == "~/dev/dev"


def test_resolve_root_nothing_found(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, no_git: None):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("MONOREPO_ROOT", raising=False)
    with pytest.raises(MonoSwitchError, match="could not locate monorepo"):
        resolve_root(None)


# --- write_target_file ---


def test_write_target_file_direct(tmp_path: Path):
    f = tmp_path / "target"
    write_target_file(f, Path("/some/repo"), "t")
    assert f.read_text() == "root=/some/repo\ntarget=t\n"


def test_write_target_file_falls_back_to_sudo(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    # A read-only location triggers the sudo tee path; provide a fake sudo
    # on PATH that emulates `sudo tee <file>`.
    f = tmp_path / "readonly" / "target"
    f.parent.mkdir()
    f.write_text("old\n")
    f.chmod(0o444)
    fake_bin = tmp_path / "fakebin"
    fake_bin.mkdir()
    sudo = fake_bin / "sudo"
    sudo.write_text(
        "#!/bin/sh\n# $1=tee $2=file; root can write anything, the stub needs chmod\n"
        'if [ "$1" = tee ]; then chmod u+w "$2"; cat > "$2"; fi\n'
    )
    sudo.chmod(0o755)
    monkeypatch.setenv("PATH", f"{fake_bin}:{os.environ['PATH']}")
    write_target_file(f, Path("/some/repo"), "t")
    assert f.read_text() == "root=/some/repo\ntarget=t\n"


# --- resolve_target ---


def test_resolve_target_flag_wins(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(sys.stdin, "isatty", lambda: True)
    assert resolve_target("t", tmp_path / "target", {"target": "cached"}, Path("/r")) == "t"


def test_resolve_target_from_cache(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture
):
    assert resolve_target(None, tmp_path / "target", {"target": "t"}, Path("/r")) == "t"
    assert "from" in capsys.readouterr().out


def test_resolve_target_no_tty_errors(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(sys.stdin, "isatty", lambda: False)
    with pytest.raises(MonoSwitchError, match="stdin is not a tty"):
        resolve_target(None, tmp_path / "target", {}, Path("/r"))


def test_resolve_target_interactive_bootstrap(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(sys.stdin, "isatty", lambda: True)
    monkeypatch.setattr("builtins.input", lambda prompt: "systems.configs.aviary")
    f = tmp_path / "target"
    assert resolve_target(None, f, {}, Path("/some/repo")) == "systems.configs.aviary"
    assert f.read_text() == "root=/some/repo\ntarget=systems.configs.aviary\n"


def test_resolve_target_interactive_retry_on_blank(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(sys.stdin, "isatty", lambda: True)
    answers = iter(["", "t"])
    monkeypatch.setattr("builtins.input", lambda prompt: next(answers))
    assert resolve_target(None, tmp_path / "target", {}, Path("/r")) == "t"


# --- build_activate ---


def fake_nix_build(
    monkeypatch: pytest.MonkeyPatch, returncode: int = 0, stdout: str = "/nix/store/xyz"
):
    calls: list[list[str]] = []

    def run(argv, **kwargs):
        calls.append(argv)
        return SimpleNamespace(returncode=returncode, stdout=stdout)

    monkeypatch.setattr(subprocess, "run", run)
    return calls


def test_build_activate_appends_suffix(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    calls = fake_nix_build(monkeypatch)
    assert build_activate(tmp_path, "systems.x") == "/nix/store/xyz"
    assert calls[0][-1] == "systems.x.activate"


def test_build_activate_accepts_explicit_suffix(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    calls = fake_nix_build(monkeypatch)
    build_activate(tmp_path, "systems.x.activate")
    assert calls[0][-1] == "systems.x.activate"


def test_build_activate_failure(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    fake_nix_build(monkeypatch, returncode=100)
    with pytest.raises(MonoSwitchError, match="nix-build failed"):
        build_activate(tmp_path, "systems.x")


def test_build_activate_empty_stdout(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    fake_nix_build(monkeypatch, stdout="  \n")
    with pytest.raises(MonoSwitchError, match="no store path"):
        build_activate(tmp_path, "systems.x")
