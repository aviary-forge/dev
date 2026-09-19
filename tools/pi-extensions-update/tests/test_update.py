"""Tests for the update pipeline's pure logic (no registry, no nix, no npm)."""

import json
from pathlib import Path

import pytest

from pi_extensions_update.update import (
    FAKE_HASH,
    UpdateError,
    fix_src_comment,
    parse_got_hash,
    rewrite_attr,
    write_versions,
)

DEFAULT_NIX = """\
{
  dev,
  members,
  ...
}:
let
  versions = builtins.fromJSON (builtins.readFile ../versions.json);
in
dev.nix.mkPiPackage {
  pname = "pi-intercom";
  version = versions.pi-intercom;
  # sha512 of the npm tarball, from registry.npmjs.org dist.integrity
  srcHash = "sha256-HYm9McpjzM2CpclQzAQ7ypnhfkZk33/ZnxaFmgRCJ58=";
  npmDepsHash = "sha256-yPdMCmEyV+TZqipz5eC8cA8k6f5FIVJovR0fUkyhBoc=";

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';
}
"""


def write_pkg(tmp_path: Path, text: str) -> Path:
    path = tmp_path / "default.nix"
    path.write_text(text)
    return path


def test_rewrite_attr_scoped_and_once(tmp_path):
    path = write_pkg(tmp_path, DEFAULT_NIX)
    rewrite_attr(path, "srcHash", "sha256-NEW=")
    text = path.read_text()
    assert 'srcHash = "sha256-NEW="' in text
    # untouched neighbours
    assert 'npmDepsHash = "sha256-yPdMCmEyV+TZqipz5eC8cA8k6f5FIVJovR0fUkyhBoc="' in text
    assert "mkPiPackage {" in text and 'pname = "pi-intercom";' in text


def test_rewrite_attr_ignores_match_outside_block(tmp_path):
    # A matching line before the mkPiPackage block must not be touched, and
    # the in-block line must still be the one rewritten.
    text = DEFAULT_NIX.replace("let\n", '  npmDepsHash = "sha256-BEFOREBLOCK=";\nlet\n', 1)
    path = write_pkg(tmp_path, text)
    rewrite_attr(path, "npmDepsHash", FAKE_HASH)
    out = path.read_text()
    assert "sha256-BEFOREBLOCK=" in out  # prelude untouched
    assert f'npmDepsHash = "{FAKE_HASH}"' in out  # in-block rewritten


def test_rewrite_attr_missing_fails(tmp_path):
    path = write_pkg(tmp_path, DEFAULT_NIX)
    with pytest.raises(UpdateError, match="0 times"):
        rewrite_attr(path, "npmName", "whatever")


def test_fix_src_comment(tmp_path):
    path = write_pkg(tmp_path, DEFAULT_NIX)
    fix_src_comment(path)
    assert "dist.integrity" not in path.read_text()
    assert "nix hash file --type sha256 --base64" in path.read_text()


def test_fix_src_comment_absent_is_noop(tmp_path):
    old = "# sha512 of the npm tarball"
    text = DEFAULT_NIX.replace(old, "## gone")
    path = write_pkg(tmp_path, text)
    fix_src_comment(path)
    assert "## gone" in path.read_text()
    assert old not in path.read_text()


def test_write_versions(tmp_path):
    path = tmp_path / "versions.json"
    path.write_text(json.dumps({"pi-intercom": "0.13.0", "@a/b": "1.0"}, indent=2) + "\n")
    write_versions(tmp_path, "pi-intercom", "0.14.0")
    out = json.loads(path.read_text())
    assert out == {"pi-intercom": "0.14.0", "@a/b": "1.0"}
    # key order preserved, file stays valid TOML-ish JSON for builtins.fromJSON
    assert path.read_text().startswith('{\n  "pi-intercom"')


def test_parse_got_hash():
    stderr = (
        "error: hash mismatch in fixed-output derivation\n"
        "         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n"
        "         got:       sha256-kXb4UoPdCU/iVsbEEW6FjcRTGWkdpBeT8jc2JbyREWk="
    )
    assert parse_got_hash(stderr) == ("sha256-kXb4UoPdCU/iVsbEEW6FjcRTGWkdpBeT8jc2JbyREWk=")


def test_parse_got_hash_absent():
    assert parse_got_hash("some other build failure") is None


def test_fix_missing_integrity(tmp_path, monkeypatch):
    from pi_extensions_update import registry
    from pi_extensions_update.update import fix_missing_integrity

    lock = {
        "lockfileVersion": 3,
        "packages": {
            "": {"name": "x", "version": "1.0.0"},
            "node_modules/@earendil-works/pi-coding-agent": {
                "version": "0.85.1",
                "resolved": "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/x.tgz",
                "integrity": "sha512-HAVE=",
            },
            "node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/chord": {
                "version": "0.85.1",
                "resolved": "https://registry.npmjs.org/@earendil-works/chord/-/chord-0.85.1.tgz",
            },
            "node_modules/file-dep": {"version": "file:../shim", "dev": True},
        },
    }
    path = tmp_path / "package-lock.json"
    path.write_text(json.dumps(lock, indent=2))

    monkeypatch.setattr(
        registry,
        "_doc_cache",
        {
            "@earendil-works/chord": {
                "versions": {"0.85.1": {"dist": {"integrity": "sha512-RESTORED=="}}}
            }
        },
    )
    fixed = fix_missing_integrity(path)
    assert fixed == 1
    out = json.loads(path.read_text())
    nested = out["packages"][
        "node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/chord"
    ]
    assert nested["integrity"] == "sha512-RESTORED=="
    # untouched: entries with integrity, and non-registry entries
    assert out["packages"]["node_modules/file-dep"] == {"version": "file:../shim", "dev": True}
