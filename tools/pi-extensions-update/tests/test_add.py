"""Tests for the add subcommand's pure logic (no network, no nix, no npm)."""

import json
from pathlib import Path

import pytest

from pi_extensions_update import add, update

SCOPED = "@plannotator/pi-extension"
UNSCOPED = "left-pad"


def render(npm_name: str, dir_name: str) -> str:
    return add.render_template(npm_name, dir_name, "sha256-PLACEHOLDER=", "sha256-PLACEHOLDER=")


def test_render_scoped_has_npm_name_and_quoted_key():
    text = render(SCOPED, "plannotator")
    assert 'npmName = "@plannotator/pi-extension";' in text
    assert 'pname = "plannotator";' in text
    # Quoted attr form works for scoped names where the bare form cannot.
    assert 'versions."@plannotator/pi-extension"' in text


def test_render_unscoped_omits_npm_name():
    text = render(UNSCOPED, UNSCOPED)
    assert "npmName" not in text
    assert 'pname = "left-pad";' in text
    assert 'versions."left-pad"' in text


def test_render_carries_todo_and_correct_hash_comment():
    text = render(SCOPED, "plannotator")
    assert "TODO(human)" in text
    # The stale sha512/dist.integrity claim must not appear in new packages.
    assert "sha256 of the npm tarball" in text
    assert "dist.integrity" not in text.split("# sha256")[0]


def test_render_is_parseable_and_nix_interpolation_survives():
    # The nix ${./package-lock.json} interpolation must survive rendering.
    text = render(SCOPED, "plannotator")
    assert "${./package-lock.json}" in text
    assert "@@" not in text


def test_derive_dir_name():
    # Scope-stripped basename; @plannotator/pi-extension -> pi-extension
    # (which is why --dir exists: plannotator was added with --dir plannotator).
    assert add.derive_dir_name(SCOPED, None) == "pi-extension"
    assert add.derive_dir_name(UNSCOPED, None) == UNSCOPED
    assert add.derive_dir_name(SCOPED, "plannotator") == "plannotator"


def test_check_collision_on_versions_entry(tmp_path: Path):
    with pytest.raises(update.UpdateError, match="already pinned"):
        add.check_collision(tmp_path, {"left-pad": "1.0.0"}, "left-pad", "left-pad")


def test_check_collision_on_existing_dir(tmp_path: Path):
    (tmp_path / "left-pad").mkdir()
    with pytest.raises(update.UpdateError, match="already exists"):
        add.check_collision(tmp_path, {}, "left-pad", "left-pad")


def test_check_collision_passes_for_new_package(tmp_path: Path):
    add.check_collision(tmp_path, {"other": "1.0.0"}, "left-pad", "left-pad")


def test_write_versions_appends_preserving_order_and_format(tmp_path: Path):
    base = tmp_path
    initial = {"a-pkg": "1.0.0", "@scope/pkg": "0.2.0"}
    (base / "versions.json").write_text(json.dumps(initial, indent=2) + "\n")

    update.write_versions(base, "left-pad", "1.3.0")
    text = (base / "versions.json").read_text()
    data = json.loads(text)
    assert data == {**initial, "left-pad": "1.3.0"}
    assert list(data) == ["a-pkg", "@scope/pkg", "left-pad"]  # appended at end
    assert text.endswith("\n")
    assert '\n  "left-pad": "1.3.0"' in text  # 2-space indent preserved


def _ns(**kw):  # lightweight argparse.Namespace stand-in
    from argparse import Namespace

    return Namespace(**kw)


def test_run_refuses_dirty_third_party(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    base = tmp_path / "third_party" / "pi-extensions"
    base.mkdir(parents=True)
    (base / "versions.json").write_text("{}\n")

    def fake_dirty_guard(_root: Path) -> None:
        raise update.UpdateError("dirty tree (simulated)")

    monkeypatch.setattr(add.discover, "repo_root", lambda: tmp_path)
    monkeypatch.setattr(add.update, "dirty_guard", fake_dirty_guard)
    rc = add.run(_ns(npm_name="left-pad", version=None, dir=None, no_build=True))
    assert rc == 1
