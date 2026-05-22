#!/usr/bin/env python3
"""Shared Checkrun schema association policy.

The policy file is intentionally data-only. This module owns the semantics for
that data so `autolint`, direct schema validation, and nvim all expand paths,
matches, and schema URLs the same way.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
from collections.abc import Iterable
from json import JSONDecodeError
from pathlib import Path
from typing import Any

# Resolve HOME once per process so CLI tools, tests, and nvim all interpret the
# same policy file against the same root. Hosts provide their policy under
# Checkrun's config namespace; the policy data may still match files owned by
# integration repos, app repos, or any other host harness.
HOME = Path.home()
CHECKRUN_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_POLICY = HOME / ".config/checkrun/associations.json"
DEFAULT_SCHEMA_DATA_DIR = ".local/share/checkrun/schemas"
DEFAULT_POLICY_SCHEMA = CHECKRUN_ROOT / "share/checkrun/schemas/associations.schema.json"


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def home_path(value: str) -> Path:
    if value.startswith("$HOME/"):
        return HOME / value[len("$HOME/") :]
    if value.startswith("~/"):
        return HOME / value[2:]
    path = Path(value)
    if path.is_absolute():
        return path
    return HOME / value


def home_string(value: str) -> str:
    # Editor-facing schema URLs can be either real URLs or file URLs. Expand
    # HOME inside file URLs without disturbing normal https:// sources.
    if value.startswith("file://$HOME"):
        return value.replace("file://$HOME", "file://" + str(HOME), 1)
    if value.startswith("file://~"):
        return value.replace("file://~", "file://" + str(HOME), 1)
    if value.startswith("$HOME/") or value.startswith("~/"):
        return str(home_path(value))
    if value.startswith("$HOME"):
        return value.replace("$HOME", str(HOME), 1)
    return value


def policy_path() -> Path:
    # CHECKRUN_SCHEMA_ASSOCIATIONS lets tests and temporary worktrees exercise
    # the same interpreter without editing the real host policy.
    value = os.environ.get("CHECKRUN_SCHEMA_ASSOCIATIONS")
    return home_path(value) if value else DEFAULT_POLICY


def policy_schema_path() -> Path:
    """Return the schema that defines association policy documents."""

    return DEFAULT_POLICY_SCHEMA


def dependency_file_path(dependency: str, asset_path: str) -> Path:
    """Resolve a dependency-owned schema asset through shdeps."""

    shdeps = shutil.which("shdeps")
    if shdeps is None:
        return Path(f"shdeps:{dependency}/{asset_path}")
    try:
        result = subprocess.run(
            [shdeps, "dep-file", dependency, asset_path],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return Path(f"shdeps:{dependency}/{asset_path}")
    if result.returncode != 0:
        return Path(f"shdeps:{dependency}/{asset_path}")
    resolved = result.stdout.strip()
    if not resolved:
        return Path(f"shdeps:{dependency}/{asset_path}")
    return Path(resolved)


def schema_path(policy: dict[str, Any], association: dict[str, Any]) -> Path:
    """Return the local schema payload path used by offline validators."""

    schema = str(association.get("schema", ""))
    if not schema:
        return Path()
    dependency = association.get("dependency")
    if isinstance(dependency, str) and dependency:
        return dependency_file_path(dependency, schema)
    if schema.startswith("file://"):
        return home_path(schema[len("file://") :])
    if schema.startswith("$HOME/") or schema.startswith("~/"):
        return home_path(schema)
    path = Path(schema)
    if path.is_absolute():
        return path
    if "/" in schema:
        # Paths with directories are host-local config/data paths. Keep them
        # anchored under HOME while bare public-schema payload names stay under
        # schemaDataDir.
        return HOME / schema
    data_dir = home_path(str(policy.get("schemaDataDir", DEFAULT_SCHEMA_DATA_DIR)))
    return data_dir / schema


def schema_url(
    policy: dict[str, Any],
    association: dict[str, Any],
    *,
    prefer_source: bool = False,
) -> str | None:
    """Return the URL a schema consumer should use for an association.

    Editors prefer `source` so hover/completion can use public schema URLs.
    Offline tools use `schema_path()` instead so hooks and CI never fetch
    network resources while validating local files.
    """

    source = association.get("source")
    if prefer_source and isinstance(source, str) and source:
        return home_string(source)

    schema = association.get("schema")
    if not isinstance(schema, str) or not schema:
        return None
    if schema.startswith(("http://", "https://", "file://")):
        return home_string(schema)
    return "file://" + str(schema_path(policy, association))


def expanded_patterns(patterns: Iterable[Any]) -> list[str]:
    """Expand one policy match into every supported consumer match form.

    Policy patterns are written once as home-relative host paths. The extra
    absolute and recursive forms make the same association work in the live
    home tree, a copied checkout, and overlay worktrees without each consumer
    re-learning that convention.
    """

    expanded: list[str] = []
    seen: set[str] = set()
    for raw in patterns:
        if not isinstance(raw, str):
            continue
        pattern = raw.strip()
        if not pattern:
            continue
        candidates = [home_string(pattern)]
        if not pattern.startswith(("/", "$HOME/", "~/")):
            candidates.extend([str(HOME / pattern), f"**/{pattern}"])
        for candidate in candidates:
            if candidate not in seen:
                seen.add(candidate)
                expanded.append(candidate)
    return expanded


def candidates(path: Path) -> set[str]:
    absolute = str(path)
    names = {absolute}
    try:
        names.add(str(path.relative_to(HOME)))
    except ValueError:
        pass
    return names


def matches(path: Path, association: dict[str, Any]) -> bool:
    names = candidates(path)
    for pattern in expanded_patterns(association.get("matches", [])):
        # fnmatch treats "/" as an ordinary character. That is intentional:
        # the policy's generated `**/foo` patterns are meant to match copied
        # checkout paths without adding another glob implementation.
        if any(fnmatch.fnmatchcase(name, pattern) for name in names):
            return True
    return False


def associations(policy: Any, *, enforce_only: bool = False) -> list[dict[str, Any]]:
    # A malformed top-level policy should never make consumers traceback. The
    # policy file itself is validated separately by schema-lint's bootstrap
    # check; other consumers can safely treat it as having no associations.
    if not isinstance(policy, dict):
        return []
    items = policy.get("associations", [])
    if not isinstance(items, list):
        return []
    return [
        item
        for item in items
        if isinstance(item, dict) and (not enforce_only or item.get("enforce") is True)
    ]


def matching_associations(policy: dict[str, Any], path: Path) -> list[dict[str, Any]]:
    return [
        association
        for association in associations(policy, enforce_only=True)
        if matches(path, association)
    ]


def append_unique(items: Iterable[str], extra: Iterable[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for item in [*items, *extra]:
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


def glob_body(pattern: str) -> str:
    return re.escape(pattern).replace(r"\-", "-").replace(r"\*\*", ".*").replace(r"\*", ".*")


def glob_to_regex(pattern: str) -> str:
    # Taplo wants regex keys, while JSON/YAML language servers accept glob-like
    # fileMatch values. Keep this conversion in the shared interpreter so TOML
    # does not drift from the path expansion used by other editor surfaces.
    body = glob_body(pattern)
    if pattern.startswith("/"):
        return "^" + body + "$"
    if pattern.startswith("**/"):
        return ".*/" + glob_body(pattern[3:]) + "$"
    return ".*/" + body + "$"


def nvim_config(policy: dict[str, Any]) -> dict[str, Any]:
    """Build editor-facing schema associations from the shared policy."""

    json_schemas: list[dict[str, Any]] = []
    yaml_schemas: dict[str, list[str]] = {}
    toml_schemas: dict[str, str] = {}

    for association in associations(policy):
        fmt = str(association.get("format", "")).lower()
        url = schema_url(policy, association, prefer_source=True)
        file_matches = expanded_patterns(association.get("matches", []))
        if not url or not file_matches:
            continue
        if fmt == "json":
            json_schemas.append(
                {
                    "name": association.get("name"),
                    "url": url,
                    "fileMatch": file_matches,
                }
            )
        elif fmt == "yaml":
            # yamlls keys schemas by URL, so distinct policy entries that use
            # the same published schema must share one deduped fileMatch list.
            yaml_schemas[url] = append_unique(yaml_schemas.get(url, []), file_matches)
        elif fmt == "toml":
            for pattern in file_matches:
                toml_schemas[glob_to_regex(pattern)] = url

    return {"json": json_schemas, "yaml": yaml_schemas, "toml": toml_schemas}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nvim", action="store_true", help="emit nvim LSP schema config")
    args = parser.parse_args(argv)

    if not args.nvim:
        parser.error("one output mode is required")

    path = policy_path()
    if not path.is_file():
        print(json.dumps({"json": [], "yaml": {}, "toml": {}}, separators=(",", ":")))
        return 0
    try:
        policy = load_json(path)
    except (JSONDecodeError, OSError) as exc:
        print(f"schema policy: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(nvim_config(policy), separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
