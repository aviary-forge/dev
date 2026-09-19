"""Tests for default.nix parsing and package model (no registry, no nix)."""

from pathlib import Path

import pytest

from pi_extensions_update.discover import Package, ParseError, parse_default_nix

SIMPLE = """\
# pi-intercom — https://www.npmjs.com/package/pi-intercom
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

  meta.owners = with members; [ denbeigh ];
}
"""

SCOPED = """\
{
  dev,
  members,
  ...
}:
let
  versions = builtins.fromJSON (builtins.readFile ../versions.json);
in
dev.nix.mkPiPackage {
  pname = "plannotator";
  npmName = "@plannotator/pi-extension";
  version = versions."@plannotator/pi-extension";
  srcHash = "sha256-CWVh8GXbiJEjrnaQ/DRBtbQEBeZpSzQvFdH8Aj/iLjo=";
  npmDepsHash = "sha256-Xyq/hGMiB8kKWP39yQBXdXkRfSC/2/oBO9iBQ7HkBx8=";
}
"""


def test_simple_package():
    attrs = parse_default_nix(SIMPLE, Path("pi-intercom/default.nix"))
    assert attrs is not None
    assert attrs.pname == "pi-intercom"
    assert attrs.npm_name == "pi-intercom"  # npmName defaults to pname
    assert attrs.src_hash == "sha256-HYm9McpjzM2CpclQzAQ7ypnhfkZk33/ZnxaFmgRCJ58="
    assert attrs.npm_deps_hash == "sha256-yPdMCmEyV+TZqipz5eC8cA8k6f5FIVJovR0fUkyhBoc="


def test_scoped_package_npm_name_wins():
    attrs = parse_default_nix(SCOPED, Path("plannotator/default.nix"))
    assert attrs is not None
    assert attrs.pname == "plannotator"
    assert attrs.npm_name == "@plannotator/pi-extension"


def test_missing_src_hash_fails():
    text = SIMPLE.replace(
        '  srcHash = "sha256-HYm9McpjzM2CpclQzAQ7ypnhfkZk33/ZnxaFmgRCJ58=";\n', ""
    )
    with pytest.raises(ParseError, match="no srcHash"):
        parse_default_nix(text, Path("x/default.nix"))


def test_not_mkpipackage_returns_none():
    assert parse_default_nix("{ stdenv }: stdenv.mkDerivation { }", Path("x/default.nix")) is None


def test_matching_outside_block_ignored():
    # A hash-shaped line before the mkPiPackage block must not be matched.
    prelude = '  # stale: srcHash = "sha256-OLDBEFOREBLOCKAAAAAAAAAAAAAAAAAAAAAAAA=";\n'
    text = SIMPLE.replace("dev.nix.mkPiPackage {", prelude + "dev.nix.mkPiPackage {")
    attrs = parse_default_nix(text, Path("x/default.nix"))
    assert attrs is not None
    assert attrs.src_hash == "sha256-HYm9McpjzM2CpclQzAQ7ypnhfkZk33/ZnxaFmgRCJ58="


def test_tarball_url_mirrors_mkpipackage():
    pkg = Package(
        dir_name="plannotator",
        pname="plannotator",
        npm_name="@plannotator/pi-extension",
        src_hash="s",
        npm_deps_hash="d",
        default_nix=Path("plannotator/default.nix"),
        pinned_version="0.27.11",
    )
    # Mirror of //nix/mkPiPackage tarballUrl: scope stripped from basename.
    assert pkg.tarball_url() == (
        "https://registry.npmjs.org/@plannotator/pi-extension/-/pi-extension-0.27.11.tgz"
    )
    assert pkg.tarball_basename == "pi-extension-0.27.11.tgz"


def test_tarball_url_unscoped():
    pkg = Package(
        dir_name="pi-intercom",
        pname="pi-intercom",
        npm_name="pi-intercom",
        src_hash="s",
        npm_deps_hash="d",
        default_nix=Path("pi-intercom/default.nix"),
        pinned_version="0.13.0",
    )
    assert pkg.tarball_url() == "https://registry.npmjs.org/pi-intercom/-/pi-intercom-0.13.0.tgz"
