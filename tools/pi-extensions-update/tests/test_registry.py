"""Tests for npm registry helpers (pure string logic, no network)."""

from pi_extensions_update.registry import encode_name


def test_encode_scoped_name():
    assert encode_name("@plannotator/pi-extension") == "%40plannotator%2Fpi-extension"


def test_encode_unscoped_name():
    assert encode_name("pi-subagents") == "pi-subagents"
