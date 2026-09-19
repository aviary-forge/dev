"""Tests for the check gate (no network, no nix)."""

from pathlib import Path

from pi_extensions_update import check, registry
from pi_extensions_update.discover import Package


def make_pkg(npm_name: str, pinned: str) -> Package:
    return Package(
        dir_name=npm_name,
        pname=npm_name,
        npm_name=npm_name,
        src_hash="sha256-src=",
        npm_deps_hash="sha256-deps=",
        default_nix=Path(f"{npm_name}/default.nix"),
        pinned_version=pinned,
    )


def write_install(node_modules: Path, npm_name: str, version: str) -> None:
    manifest = node_modules.joinpath(*npm_name.split("/"), "package.json")
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(f'{{"name": "{npm_name}", "version": "{version}"}}')


PACKAGES = [make_pkg("pi-a", "1.0.0"), make_pkg("pi-b", "2.0.0")]


def test_collect_latest_stale_and_current():
    latest = {"pi-a": "1.0.0", "pi-b": "2.3.0"}
    stales, failures = check.collect(
        "latest", PACKAGES, Path("/nonexistent"), latest_fn=latest.__getitem__
    )
    assert failures == []
    assert stales == [check.Stale("pi-b", "2.0.0", "2.3.0")]


def test_collect_latest_registry_error_is_failure_not_stale():
    def boom(_name: str) -> str:
        raise registry.RegistryError("registry unreachable")

    stales, failures = check.collect("latest", PACKAGES, Path("/nonexistent"), latest_fn=boom)
    assert stales == []
    assert failures == [
        check.CheckFailure("pi-a", "registry unreachable"),
        check.CheckFailure("pi-b", "registry unreachable"),
    ]


def test_collect_installed_current_and_stale(tmp_path: Path):
    write_install(tmp_path, "pi-a", "1.0.0")
    write_install(tmp_path, "pi-b", "2.0.0")
    stales, failures = check.collect("installed", PACKAGES, tmp_path)
    assert failures == []
    assert stales == []


def test_collect_installed_missing_is_stale_not_failure(tmp_path: Path):
    write_install(tmp_path, "pi-a", "1.0.0")
    stales, failures = check.collect("installed", PACKAGES, tmp_path)
    assert failures == []
    assert stales == [check.Stale("pi-b", "2.0.0", "<not installed>")]


def test_collect_installed_scoped_name_layout(tmp_path: Path):
    pkg = make_pkg("@scope/pi-c", "0.1.0")
    write_install(tmp_path, "@scope/pi-c", "0.1.0")
    stales, failures = check.collect("installed", [pkg], tmp_path)
    assert stales == []
    assert failures == []


def test_exit_code_failure_outranks_stale():
    stales = [check.Stale("pi-a", "1.0.0", "2.0.0")]
    failures = [check.CheckFailure("pi-b", "boom")]
    # A partial failure must not be reported as merely stale or clean.
    assert check.exit_code(stales, failures) == 2
    assert check.exit_code([], failures) == 2
    assert check.exit_code(stales, []) == 1
    assert check.exit_code([], []) == 0


def test_collect_latest_mismatch_only_when_different():
    pkg = make_pkg("pi-a", "1.0.0")

    stales, failures = check.collect(
        "latest", [pkg], Path("/nonexistent"), latest_fn=lambda _: "1.0.0"
    )
    assert stales == [] and failures == []
