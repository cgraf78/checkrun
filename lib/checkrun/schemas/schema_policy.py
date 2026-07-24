#!/usr/bin/env python3
"""Shared Checkrun schema association policy interpreter.

The policy file is intentionally data-only. This module owns the semantics for
that data so `autolint`, direct schema validation, and editor integrations all
expand paths, matches, and schema URLs the same way.

Public contract:
  - `schema_policy.py --lsp-schemas [--editor-sources]`
  - `load_json()`
  - `load_policy()`
  - `policy_path()`
  - `policy_schema_path()`
  - `schema_path()`
  - `schema_url()`
  - `matching_associations()`
  - `lsp_schema_config()`

The functions outside `__all__` are implementation details. Keeping that line
clear matters because this file is dependency-addressable through shdeps, so any
unmarked helper can otherwise become a de facto integration API.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import shutil
import stat
import subprocess
import sys
from collections.abc import Iterable
from functools import lru_cache
from json import JSONDecodeError
from pathlib import Path
from typing import Any

_MODULE_DIR = Path(__file__).resolve().parent.parent
if str(_MODULE_DIR) not in sys.path:
    sys.path.insert(0, str(_MODULE_DIR))

import checkrun_paths  # noqa: E402  # Direct script loads parent-owned policy.

PathPolicyError = checkrun_paths.PathPolicyError


class SchemaPolicyError(ValueError):
    """An active schema association policy cannot be parsed or validated."""


class _ValidatedPolicy(dict[str, Any]):
    """Marker for a policy that passed the repository-owned shape contract."""


_CHECKRUN_ROOT = Path(__file__).resolve().parents[3]
_DEFAULT_POLICY_SCHEMA = _CHECKRUN_ROOT / "share/checkrun/schemas/associations.schema.json"
_POLICY_FIELDS = frozenset({"version", "schemaDataDir", "associations"})
_POLICY_REQUIRED = frozenset({"version", "associations"})
_ASSOCIATION_FIELDS = frozenset(
    {
        "name",
        "format",
        "schema",
        "dependency",
        "source",
        "editorSource",
        "matches",
        "enforce",
        "note",
    }
)
_ASSOCIATION_REQUIRED = frozenset({"name", "format", "matches", "enforce"})
_FORMATS = frozenset({"json", "yaml", "toml"})
_MISSING_POLICY = object()

__all__ = [
    "PathPolicyError",
    "SchemaPolicyError",
    "load_json",
    "load_policy",
    "validate_policy",
    "policy_path",
    "policy_schema_path",
    "schema_path",
    "schema_url",
    "matching_associations",
    "lsp_schema_config",
]


@lru_cache(maxsize=1)
def _home() -> Path:
    """Resolve HOME once, and only for policy forms whose contract requires it."""

    return checkrun_paths.home_dir()


def load_json(path: Path) -> Any:
    """Load a JSON policy or schema document from `path`."""

    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def _load_active_policy(path: Path) -> Any:
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise SchemaPolicyError(f"schema policy is not a regular file: {path}")
        file = os.fdopen(descriptor, "r", encoding="utf-8")
        descriptor = -1
        with file:
            return json.load(file)
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _load_policy_document(path: Path, *, optional: bool = False) -> Any:
    """Load raw active-policy JSON through one checked file descriptor."""

    try:
        return _load_active_policy(path)
    except FileNotFoundError as exc:
        if optional:
            # Unlike exists(), lstat() observes a dangling final symlink. It
            # only classifies ENOENT; the descriptor still owns all reads.
            try:
                os.lstat(path)
            except FileNotFoundError:
                return _MISSING_POLICY
            except OSError as lstat_exc:
                raise SchemaPolicyError(
                    f"cannot read schema policy {path}: {lstat_exc}"
                ) from lstat_exc
        raise SchemaPolicyError(f"cannot read schema policy {path}: {exc}") from exc
    except SchemaPolicyError:
        raise
    except UnicodeError as exc:
        raise SchemaPolicyError(f"invalid UTF-8 in schema policy {path}: {exc}") from exc
    except JSONDecodeError as exc:
        raise SchemaPolicyError(f"invalid JSON in schema policy {path}: {exc}") from exc
    except (ValueError, RecursionError) as exc:
        raise SchemaPolicyError(f"invalid JSON in schema policy {path}: {exc}") from exc
    except OSError as exc:
        raise SchemaPolicyError(f"cannot read schema policy {path}: {exc}") from exc


def _nonempty_string(value: Any, field: str) -> None:
    if not isinstance(value, str) or not value:
        raise SchemaPolicyError(f"{field} must be a non-empty string")
    if re.search(r"[\x00-\x1F\x7F]", value):
        raise SchemaPolicyError(f"{field} must not contain control characters")


def _validate_association(value: Any, index: int) -> None:
    field = f"associations[{index}]"
    if not isinstance(value, dict):
        raise SchemaPolicyError(f"{field} must be an object")

    unexpected = sorted(set(value) - _ASSOCIATION_FIELDS)
    if unexpected:
        raise SchemaPolicyError(f"{field} has unknown field {unexpected[0]!r}")

    for required in sorted(_ASSOCIATION_REQUIRED):
        if required not in value:
            raise SchemaPolicyError(f"{field}.{required} is required")

    _nonempty_string(value["name"], f"{field}.name")
    if not isinstance(value["format"], str) or value["format"] not in _FORMATS:
        raise SchemaPolicyError(f"{field}.format must be one of json, yaml, or toml")

    matches = value["matches"]
    if not isinstance(matches, list) or not matches:
        raise SchemaPolicyError(f"{field}.matches must be a non-empty array")
    for match_index, match in enumerate(matches):
        _nonempty_string(match, f"{field}.matches[{match_index}]")

    if not isinstance(value["enforce"], bool):
        raise SchemaPolicyError(f"{field}.enforce must be a boolean")

    for optional in ("schema", "dependency", "source", "editorSource", "note"):
        if optional in value:
            _nonempty_string(value[optional], f"{field}.{optional}")

    if "schema" not in value and "editorSource" not in value:
        raise SchemaPolicyError(f"{field} requires schema or editorSource")
    if value["enforce"] is True and "schema" not in value:
        raise SchemaPolicyError(f"{field}.schema is required when enforce is true")
    if "source" in value and "schema" not in value:
        raise SchemaPolicyError(f"{field}.schema is required when source is set")


def validate_policy(policy: Any, *, path: Path | None = None) -> dict[str, Any]:
    """Validate and return one active schema association policy."""

    if isinstance(policy, _ValidatedPolicy):
        return policy
    suffix = f": {path}" if path is not None else ""
    if not isinstance(policy, dict):
        raise SchemaPolicyError(f"schema policy must be a JSON object{suffix}")

    unexpected = sorted(set(policy) - _POLICY_FIELDS)
    if unexpected:
        raise SchemaPolicyError(f"schema policy has unknown field {unexpected[0]!r}{suffix}")
    missing = sorted(_POLICY_REQUIRED - set(policy))
    if missing:
        raise SchemaPolicyError(f"schema policy {missing[0]} is required{suffix}")
    version = policy["version"]
    if isinstance(version, bool) or not isinstance(version, (int, float)) or version != 1:
        raise SchemaPolicyError(f"schema policy version must be 1{suffix}")
    if "associations" not in policy:
        raise SchemaPolicyError(f"schema policy associations is required{suffix}")
    associations = policy["associations"]
    if not isinstance(associations, list):
        raise SchemaPolicyError(f"schema policy associations must be an array{suffix}")
    if not associations:
        raise SchemaPolicyError(f"schema policy associations must not be empty{suffix}")
    try:
        if "schemaDataDir" in policy:
            _nonempty_string(policy["schemaDataDir"], "schema policy schemaDataDir")
        for index, association in enumerate(associations):
            _validate_association(association, index)
    except SchemaPolicyError as exc:
        raise SchemaPolicyError(f"{exc}{suffix}") from exc
    return _ValidatedPolicy(policy)


def load_policy(path: Path | None = None) -> dict[str, Any] | None:
    """Load an optional active policy, rejecting malformed or unreadable files."""

    target = path if path is not None else policy_path()
    policy = _load_policy_document(target, optional=True)
    if policy is _MISSING_POLICY:
        return None
    return validate_policy(policy, path=target)


def _home_path(value: str) -> Path:
    if value.startswith("$HOME/"):
        return _home() / value[len("$HOME/") :]
    if value.startswith("~/"):
        return _home() / value[2:]
    path = Path(value)
    if path.is_absolute():
        return path
    return _home() / value


def _home_string(value: str) -> str:
    # Editor-facing schema URLs can be either real URLs or file URLs. Expand
    # HOME inside file URLs without disturbing normal https:// sources.
    if value.startswith("file://$HOME"):
        return value.replace("file://$HOME", "file://" + str(_home()), 1)
    if value.startswith("file://~"):
        return value.replace("file://~", "file://" + str(_home()), 1)
    if value.startswith("$HOME/") or value.startswith("~/"):
        return str(_home_path(value))
    if value.startswith("$HOME"):
        return value.replace("$HOME", str(_home()), 1)
    return value


def policy_path() -> Path:
    """Return the active schema association policy path."""

    # CHECKRUN_SCHEMA_ASSOCIATIONS lets tests and temporary worktrees exercise
    # the same interpreter without editing the real host policy.
    value = os.environ.get("CHECKRUN_SCHEMA_ASSOCIATIONS")
    return _home_path(value) if value else checkrun_paths.config_dir() / "associations.json"


def policy_schema_path() -> Path:
    """Return the schema that defines association policy documents.

    This is a checkrun-owned constant, not a host-variable path: the schema
    travels with the checkrun checkout/dependency, so consumers cannot override
    it. The function form (rather than re-exporting the constant directly)
    keeps callers from importing a private name and is reserved as a hook for a
    future override knob if a real need ever appears.
    """

    return _DEFAULT_POLICY_SCHEMA


# Per-process stderr notices for shdeps resolution failures. Without this
# cache, a host running schema validation across N associated files in ONE
# Python invocation (e.g. the batched planner in registry.py) would log one
# "schema file not found: shdeps:…" diagnostic per file per dependency. The
# fallback bogus path is still returned so downstream code does not crash.
#
# Note: schema-lint.py invokes itself per file, so the cache only collapses
# notices *within* one invocation — across N files you can still see N
# notices. Batching schema-lint to accept multiple files would extend the
# de-duplication across that path too; not done here.
_SHDEPS_NOTICES: set[tuple[str, str]] = set()


def _shdeps_notice_once(dependency: str, kind: str, detail: str = "") -> None:
    key = (dependency, kind)
    if key in _SHDEPS_NOTICES:
        return
    _SHDEPS_NOTICES.add(key)
    suffix = f": {detail}" if detail else ""
    if kind == "missing":
        print(
            f"schema_policy: shdeps not installed; cannot resolve schema asset "
            f"for dependency {dependency!r}{suffix}",
            file=sys.stderr,
        )
    else:
        print(
            f"schema_policy: shdeps failed to resolve dependency {dependency!r} ({kind}){suffix}",
            file=sys.stderr,
        )


def _dependency_file_path(dependency: str, asset_path: str) -> Path:
    """Resolve a dependency-owned schema asset through shdeps."""

    # The "shdeps:dep/asset" sentinel preserves the legacy contract (callers
    # always get back a Path), but the stderr notice above ensures operators
    # see exactly why validation will fail for that dependency — once per cause,
    # not once per file.
    shdeps = shutil.which("shdeps")
    if shdeps is None:
        _shdeps_notice_once(dependency, "missing")
        return Path(f"shdeps:{dependency}/{asset_path}")
    try:
        result = subprocess.run(
            [shdeps, "dep-file", dependency, asset_path],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (OSError, ValueError) as exc:
        _shdeps_notice_once(dependency, "oserror", str(exc))
        return Path(f"shdeps:{dependency}/{asset_path}")
    if result.returncode != 0:
        _shdeps_notice_once(dependency, "exit", f"rc={result.returncode}")
        return Path(f"shdeps:{dependency}/{asset_path}")
    resolved = result.stdout.strip()
    if not resolved:
        _shdeps_notice_once(dependency, "empty")
        return Path(f"shdeps:{dependency}/{asset_path}")
    return Path(resolved)


def schema_path(policy: dict[str, Any], association: dict[str, Any]) -> Path:
    """Return the local schema payload path used by offline validators."""

    schema = str(association.get("schema", ""))
    if not schema:
        return Path()
    dependency = association.get("dependency")
    if isinstance(dependency, str) and dependency:
        return _dependency_file_path(dependency, schema)
    if schema.startswith("file://"):
        return _home_path(schema[len("file://") :])
    if schema.startswith("$HOME/") or schema.startswith("~/"):
        return _home_path(schema)
    path = Path(schema)
    if path.is_absolute():
        return path
    if "/" in schema:
        # Paths with directories are host-local config/data paths. Keep them
        # anchored under HOME while bare public-schema payload names stay under
        # schemaDataDir.
        return _home() / schema
    configured_data_dir = policy.get("schemaDataDir")
    data_dir = (
        _home_path(str(configured_data_dir))
        if "schemaDataDir" in policy
        else checkrun_paths.data_dir() / "checkrun/schemas"
    )
    return data_dir / schema


def schema_url(
    policy: dict[str, Any],
    association: dict[str, Any],
    *,
    prefer_source: bool = False,
    editor_sources: bool = False,
) -> str | None:
    """Return the URL a schema consumer should use for an association.

    Editors prefer `editorSource` and then `source` so hover/completion can use
    public or editor-native schema URLs. Offline tools use `schema_path()`
    instead so hooks and CI never fetch network resources while validating local
    files.
    """

    editor_source = association.get("editorSource")
    if editor_sources and prefer_source and isinstance(editor_source, str) and editor_source:
        return _home_string(editor_source)

    source = association.get("source")
    if prefer_source and isinstance(source, str) and source:
        return _home_string(source)

    schema = association.get("schema")
    if not isinstance(schema, str) or not schema:
        return None
    if schema.startswith(("http://", "https://", "file://")):
        return _home_string(schema)
    return "file://" + str(schema_path(policy, association))


def _expanded_patterns(patterns: Iterable[Any]) -> list[str]:
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
        candidates = [_home_string(pattern)]
        if not pattern.startswith(("/", "$HOME/", "~/")):
            candidates.extend([str(_home() / pattern), f"**/{pattern}"])
        for candidate in candidates:
            if candidate not in seen:
                seen.add(candidate)
                expanded.append(candidate)
    return expanded


def _candidates(path: Path) -> set[str]:
    absolute = str(path)
    names = {absolute}
    try:
        names.add(str(path.relative_to(_home())))
    except ValueError:
        pass
    return names


def _matches(path: Path, association: dict[str, Any]) -> bool:
    names = _candidates(path)
    for pattern in _expanded_patterns(association.get("matches", [])):
        # fnmatch treats "/" as an ordinary character. That is intentional:
        # the policy's generated `**/foo` patterns are meant to match copied
        # checkout paths without adding another glob implementation.
        if any(fnmatch.fnmatchcase(name, pattern) for name in names):
            return True
    return False


def _associations(policy: Any, *, enforce_only: bool = False) -> list[dict[str, Any]]:
    items = validate_policy(policy)["associations"]
    return [item for item in items if not enforce_only or item.get("enforce") is True]


def matching_associations(policy: dict[str, Any], path: Path) -> list[dict[str, Any]]:
    """Return enforceable schema associations that match `path`."""

    return [
        association
        for association in _associations(policy, enforce_only=True)
        if _matches(path, association)
    ]


def _append_unique(items: Iterable[str], extra: Iterable[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for item in [*items, *extra]:
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


def _glob_body(pattern: str) -> str:
    return re.escape(pattern).replace(r"\-", "-").replace(r"\*\*", ".*").replace(r"\*", ".*")


def _glob_to_regex(pattern: str) -> str:
    # Taplo wants regex keys, while JSON/YAML language servers accept glob-like
    # fileMatch values. Keep this conversion in the shared interpreter so TOML
    # does not drift from the path expansion used by other editor surfaces.
    body = _glob_body(pattern)
    if pattern.startswith("/"):
        return "^" + body + "$"
    if pattern.startswith("**/"):
        return ".*/" + _glob_body(pattern[3:]) + "$"
    return ".*/" + body + "$"


def lsp_schema_config(policy: dict[str, Any], *, editor_sources: bool = False) -> dict[str, Any]:
    """Build LSP/editor-facing schema associations from the shared policy."""

    json_schemas: list[dict[str, Any]] = []
    yaml_schemas: dict[str, list[str]] = {}
    toml_schemas: dict[str, str] = {}

    for association in _associations(policy):
        fmt = str(association.get("format", "")).lower()
        url = schema_url(policy, association, prefer_source=True, editor_sources=editor_sources)
        file_matches = _expanded_patterns(association.get("matches", []))
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
            yaml_schemas[url] = _append_unique(yaml_schemas.get(url, []), file_matches)
        elif fmt == "toml":
            for pattern in file_matches:
                toml_schemas[_glob_to_regex(pattern)] = url

    return {"json": json_schemas, "yaml": yaml_schemas, "toml": toml_schemas}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lsp-schemas", action="store_true", help="emit LSP schema config")
    parser.add_argument(
        "--editor-sources",
        action="store_true",
        help="prefer editor-native schema URIs such as vscode:// where present",
    )
    args = parser.parse_args(argv)

    if not args.lsp_schemas:
        parser.error("one output mode is required")

    try:
        path = policy_path()
        policy = load_policy(path)
        if policy is None:
            print(json.dumps({"json": [], "yaml": {}, "toml": {}}, separators=(",", ":")))
            return 0
        config = lsp_schema_config(policy, editor_sources=args.editor_sources)
    except PathPolicyError as exc:
        print(f"schema policy: {exc}", file=sys.stderr)
        return 1
    except SchemaPolicyError as exc:
        print(f"schema policy: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(config, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
