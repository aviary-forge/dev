"""npm registry access (stdlib only).

The full registry doc JSON for a name is fetched once per run and cached;
all lookups (dist-tags, version metadata) derive from it.
"""

from __future__ import annotations

import json
import urllib.parse
import urllib.request

REGISTRY = "https://registry.npmjs.org"

_doc_cache: dict[str, dict] = {}


class RegistryError(Exception):
    """The npm registry could not be queried or returned unusable data."""


def encode_name(npm_name: str) -> str:
    """URL-encode an npm name for the registry doc endpoint (@scope/name)."""
    return urllib.parse.quote(npm_name, safe="")


def fetch_doc(npm_name: str) -> dict:
    """GET the full registry document for a package (cached per run)."""
    if npm_name not in _doc_cache:
        url = f"{REGISTRY}/{encode_name(npm_name)}"
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                _doc_cache[npm_name] = json.load(resp)
        except (OSError, ValueError) as e:
            raise RegistryError(f"failed to fetch registry doc for {npm_name}: {e}") from e
    return _doc_cache[npm_name]


def latest_version(npm_name: str) -> str:
    doc = fetch_doc(npm_name)
    try:
        return str(doc["dist-tags"]["latest"])
    except (KeyError, TypeError) as e:
        raise RegistryError(f"{npm_name}: registry doc has no dist-tags.latest") from e


def resolve_version(npm_name: str, requested: str | None) -> str:
    """Resolve the target version: explicit, or dist-tags.latest."""
    return requested if requested is not None else latest_version(npm_name)
