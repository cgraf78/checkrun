#!/usr/bin/env python3
"""Internal interpreter for Checkrun's tooling registry.

Public contract:
  - `checkrun registry --json`
  - `checkrun capabilities --json`
  - `checkrun explain [--json] FILE...`
  - `checkrun plan --json [--phase format|lint] FILE...`

This module is intentionally not a general-purpose library API. A tiny Python
facade is kept documented for repo tests and future Checkrun-owned callers, but
downstream integrations should consume the CLI JSON contracts instead. Keeping
that boundary explicit prevents helper functions from becoming accidental public
API just because they live in a sourceable dependency checkout.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import sys
from json import JSONDecodeError
from pathlib import Path
from typing import Any

import tomllib

__all__ = [
    "RegistryError",
    "load_registry",
    "plan",
    "capabilities",
    "explain_items",
    "resolve_config",
]

_CHECKRUN_ROOT = Path(__file__).resolve().parents[2]
_REGISTRY_PATH = _CHECKRUN_ROOT / "share/checkrun/registry.json"
_REGISTRY_SCHEMA_PATH = _CHECKRUN_ROOT / "share/checkrun/schemas/registry.schema.json"
_LINTER_ADAPTER_DIR = _CHECKRUN_ROOT / "lib/checkrun/linters"

# Keep phase names centralized because the registry is now the contract shared by
# shell hooks, CLI explainability, and editor integrations. If a new phase is
# introduced in only one caller, drift comes back immediately.
_PHASES = {"format", "lint", "spell", "schema", "tool"}
_PLAN_PHASES = {"format", "lint"}
_AUTOMATIC_LINT_SCOPES = {"file"}
_DOWNSTREAM_KEYS = {"sley", "nvim"}
_PHASE_IGNORE_FILES = {
    "format": "format-ignore",
    "lint": "lint-ignore",
    "spell": "spell-ignore",
    "schema": "schema-ignore",
    "tool": "tool-ignore",
}
_SHELL_ADAPTER_SOURCES = (
    _CHECKRUN_ROOT / "lib/checkrun/autoformat.sh",
    _CHECKRUN_ROOT / "lib/checkrun/autolint.sh",
    _CHECKRUN_ROOT / "lib/checkrun/common.sh",
)
_SHELL_DISPATCH = {
    "format": (_CHECKRUN_ROOT / "lib/checkrun/autoformat.sh", "_format_dispatch()"),
    "lint": (_CHECKRUN_ROOT / "lib/checkrun/autolint.sh", "_lint_dispatch()"),
}


class RegistryError(RuntimeError):
    """Raised when the registry cannot be loaded or validated."""


def _shell_functions() -> set[str]:
    """Return shell functions available to registry-declared adapters."""

    # Adapter existence is an interpreter invariant, not just a test nicety:
    # once the registry drives execution, a typo in `adapters.*.function` would
    # otherwise make metadata look valid while shell dispatch can never run it.
    # A small static scan is enough here because Checkrun adapters are ordinary
    # top-level shell functions, and scanning avoids sourcing hook code during
    # registry load.
    functions: set[str] = set()
    pattern = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\))?\s*\{")
    # Top-level entry libraries are explicit, while linter domains are globbed
    # so adding a new `linters/*.sh` file does not create a second maintenance
    # point in the registry validator.
    sources = sorted((*_SHELL_ADAPTER_SOURCES, *_LINTER_ADAPTER_DIR.glob("*.sh")))
    for source in sources:
        try:
            lines = source.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            raise RegistryError(f"adapter source unavailable: {source}: {exc}") from exc
        for line in lines:
            match = pattern.match(line)
            if match:
                functions.add(match.group(1))
    return functions


def _shell_dispatch_functions(phase: str) -> dict[str, str]:
    """Return adapter ids and shell functions accepted by one dispatcher."""

    # The registry can only be authoritative if a selected adapter is known to
    # cross the Python-to-shell boundary. Function existence alone is not enough:
    # a custom registry can point at a real helper such as `_lint_ruff`, but the
    # shell entrypoint still needs an adapter arm that calls that same helper with
    # the right arguments. This narrow parser intentionally supports Checkrun's
    # one-line dispatch arms instead of trying to understand arbitrary shell.
    try:
        source, function = _SHELL_DISPATCH[phase]
    except KeyError as exc:
        raise RegistryError(f"unknown dispatch phase: {phase}") from exc
    try:
        lines = source.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise RegistryError(f"dispatch source unavailable: {source}: {exc}") from exc

    in_function = False
    dispatch: dict[str, str] = {}
    arm = re.compile(r"^\s+([A-Za-z0-9_.+-]+)\)\s+([A-Za-z_][A-Za-z0-9_]*)\b")
    for line in lines:
        if not in_function:
            stripped = line.strip()
            if stripped.startswith(function) or stripped.startswith(
                function.replace("()", "") + "()"
            ):
                in_function = True
            continue
        if line == "}":
            break
        match = arm.match(line)
        if match and match.group(1) != "*":
            dispatch[match.group(1)] = match.group(2)
    if not dispatch:
        raise RegistryError(f"{phase}: dispatch adapter table could not be read")
    return dispatch


def _load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8") as file:
            return json.load(file)
    except FileNotFoundError as exc:
        raise RegistryError(f"registry file not found: {path}") from exc
    except JSONDecodeError as exc:
        raise RegistryError(f"{path}: invalid JSON: {exc}") from exc
    except OSError as exc:
        raise RegistryError(f"{path}: {exc}") from exc


def _schema_ref(schema: dict[str, Any], ref: str) -> dict[str, Any]:
    # Runtime validation must stay dependency-free for editor and hook latency.
    # The registry schema intentionally uses only a small JSON Schema subset, so
    # a compact local walker is enough for production while tests can still run
    # the full jsonschema package when it is installed.
    prefix = "#/$defs/"
    if not ref.startswith(prefix):
        raise RegistryError(f"unsupported schema reference: {ref}")
    node: Any = schema
    for part in ref[len("#/") :].split("/"):
        if not isinstance(node, dict) or part not in node:
            raise RegistryError(f"unresolved schema reference: {ref}")
        node = node[part]
    if not isinstance(node, dict):
        raise RegistryError(f"schema reference does not point to an object: {ref}")
    return node


def _type_name(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int) and not isinstance(value, bool):
        return "integer"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def _validate_schema_node(
    value: Any,
    node: dict[str, Any],
    full_schema: dict[str, Any],
    path: str,
) -> None:
    # This is not a general-purpose JSON Schema engine. It is deliberately a
    # narrow validator for the schema constructs Checkrun owns: type, const,
    # enum, required, properties, additionalProperties, items, and local $defs.
    # Keeping the subset explicit prevents optional Python dependencies from
    # becoming part of the hot-path contract by accident.
    if "$ref" in node:
        _validate_schema_node(value, _schema_ref(full_schema, str(node["$ref"])), full_schema, path)
        return

    if "const" in node and value != node["const"]:
        raise RegistryError(f"{path}: expected {node['const']!r}")

    if "enum" in node and value not in node["enum"]:
        expected = ", ".join(repr(item) for item in node["enum"])
        raise RegistryError(f"{path}: expected one of {expected}")

    expected_type = node.get("type")
    if expected_type is not None:
        type_ok = (
            expected_type == "object"
            and isinstance(value, dict)
            or expected_type == "array"
            and isinstance(value, list)
            or expected_type == "string"
            and isinstance(value, str)
            or expected_type == "integer"
            and isinstance(value, int)
            and not isinstance(value, bool)
            or expected_type == "boolean"
            and isinstance(value, bool)
        )
        if not type_ok:
            raise RegistryError(f"{path}: expected {expected_type}, got {_type_name(value)}")

    if isinstance(value, dict):
        required = node.get("required", [])
        for key in required:
            if key not in value:
                raise RegistryError(f"{path}: missing required key {key!r}")

        properties = node.get("properties", {})
        additional = node.get("additionalProperties", True)
        for key, item in value.items():
            child_path = f"{path}.{key}" if path else key
            if key in properties:
                _validate_schema_node(item, properties[key], full_schema, child_path)
            elif additional is False:
                raise RegistryError(f"{child_path}: unknown key")
            elif isinstance(additional, dict):
                _validate_schema_node(item, additional, full_schema, child_path)

    if isinstance(value, list) and isinstance(node.get("items"), dict):
        for index, item in enumerate(value):
            _validate_schema_node(item, node["items"], full_schema, f"{path}[{index}]")


def _validate_shape(registry: dict[str, Any], schema: dict[str, Any]) -> None:
    _validate_schema_node(registry, schema, schema, "registry")


def _validate_invariants(registry: dict[str, Any]) -> None:
    # JSON Schema can prove the document shape, but not the cross-object
    # relationships that make the registry trustworthy as a source of truth.
    # These checks are the drift guard: metadata cannot advertise an adapter,
    # config policy, or filetype that execution cannot understand.
    if _DOWNSTREAM_KEYS.intersection(registry):
        keys = ", ".join(sorted(_DOWNSTREAM_KEYS.intersection(registry)))
        raise RegistryError(f"downstream-specific registry keys are not allowed: {keys}")

    declared_filetypes = _declared_filetypes(registry)
    _validate_editor_language_ids(registry, declared_filetypes)

    adapters = registry["adapters"]
    config_policies = registry["configPolicies"]
    dispatch_functions = {phase: _shell_dispatch_functions(phase) for phase in _PLAN_PHASES}
    dispatch_adapter_ids = {
        adapter_id for dispatch in dispatch_functions.values() for adapter_id in dispatch
    }
    unknown_dispatch = dispatch_adapter_ids.difference(adapters)
    if unknown_dispatch:
        names = ", ".join(sorted(unknown_dispatch))
        raise RegistryError(f"shell dispatch references unknown registry adapters: {names}")
    # Dispatch arms are executable shell behavior. If the registry marks an
    # adapter as internal-only, allowing a shell arm for it would create a hidden
    # second source of truth even when no selector currently chooses that adapter.
    non_shell_dispatch = {
        adapter_id
        for adapter_id in dispatch_adapter_ids
        if adapters[adapter_id].get("kind") != "shell-function"
    }
    if non_shell_dispatch:
        names = ", ".join(sorted(non_shell_dispatch))
        raise RegistryError(f"shell dispatch references non-shell adapters: {names}")

    implemented_functions = _shell_functions()
    for adapter_id, adapter in adapters.items():
        if adapter.get("kind") == "shell-function" and not adapter.get("function"):
            raise RegistryError(f"{adapter_id}: shell-function adapter requires function")
        if (
            adapter.get("kind") == "shell-function"
            and adapter["function"] not in implemented_functions
        ):
            raise RegistryError(
                f"{adapter_id}: shell-function adapter is not implemented: {adapter['function']}"
            )
        for phase, dispatch in dispatch_functions.items():
            if adapter_id in dispatch and adapter.get("kind") == "shell-function":
                dispatch_function = dispatch[adapter_id]
                if adapter["function"] != dispatch_function:
                    raise RegistryError(
                        f"{adapter_id}: adapter dispatch function mismatch in {phase}: "
                        f"registry declares {adapter['function']}, "
                        f"shell dispatch calls {dispatch_function}"
                    )

    selectors_seen: set[str] = set()
    selected_adapters: set[str] = set()
    for selector in registry["selectors"]:
        selector_id = selector["id"]
        if selector_id in selectors_seen:
            raise RegistryError(f"duplicate selector id: {selector_id}")
        selectors_seen.add(selector_id)
        if _DOWNSTREAM_KEYS.intersection(selector):
            keys = ", ".join(sorted(_DOWNSTREAM_KEYS.intersection(selector)))
            raise RegistryError(f"{selector_id}: downstream-specific keys are not allowed: {keys}")
        if not selector.get("filetypes"):
            raise RegistryError(f"{selector_id}: selector requires at least one filetype")
        for filetype in selector.get("filetypes", []):
            if filetype not in declared_filetypes:
                raise RegistryError(f"{selector_id}: undeclared filetype: {filetype}")
        for phase in ("format", "lint"):
            for step in selector.get(phase, []):
                selected_adapters.add(step["adapter"])
                _validate_step(
                    step,
                    phase,
                    selector_id,
                    adapters,
                    config_policies,
                    dispatch_functions[phase],
                    {"format"} if phase == "format" else {"lint", "tool"},
                )

    for phase, steps in registry.get("crossCutting", {}).items():
        if phase not in _PLAN_PHASES:
            raise RegistryError(f"unknown cross-cutting phase: {phase}")
        for step in steps:
            step_phase = str(step.get("phase", phase))
            if step_phase not in _PHASES:
                raise RegistryError(f"unknown step phase: {step_phase}")
            if "pathPatterns" in step:
                raise RegistryError(
                    f"crossCutting.{phase}: pathPatterns are selector-only; "
                    "cross-cutting steps apply to every lintable file"
                )
            selected_adapters.add(step["adapter"])
            _validate_step(
                step,
                phase,
                f"crossCutting.{phase}",
                adapters,
                config_policies,
                dispatch_functions[phase],
                {"spell", "schema"},
            )

    unused_adapters = {
        adapter_id
        for adapter_id, adapter in adapters.items()
        if adapter.get("kind") != "internal" and adapter_id not in selected_adapters
    }
    if unused_adapters:
        names = ", ".join(sorted(unused_adapters))
        raise RegistryError(f"unused shell-function adapters are not allowed: {names}")

    for item in registry["filetypes"]["shebangs"]:
        has_contains = "contains" in item
        has_any = "containsAny" in item
        if has_contains == has_any:
            raise RegistryError("shebang rule must contain exactly one matcher")


def _declared_filetypes(registry: dict[str, Any]) -> set[str]:
    """Return filetypes that Checkrun can infer directly from a file."""

    filetypes = registry["filetypes"]
    declared = set(filetypes["extension"].values())
    declared.update(filetypes["filename"].values())
    declared.update(item["filetype"] for item in filetypes["patterns"])
    declared.update(item["filetype"] for item in filetypes["shebangs"])
    return declared


def _validate_editor_language_ids(
    registry: dict[str, Any],
    declared_filetypes: set[str],
) -> None:
    """Validate editor language aliases against Checkrun's normalized filetypes."""

    # Editor language IDs are aliases for Checkrun's own filetypes, not a second
    # inference layer. Validating them here keeps VS Code, Neovim, hooks, and
    # CLI output on one vocabulary even as individual editors spell a few
    # languages differently.
    for editor, aliases in registry["editorLanguageIds"].items():
        for filetype, language_ids in aliases.items():
            if filetype not in declared_filetypes:
                raise RegistryError(f"editorLanguageIds.{editor}: undeclared filetype: {filetype}")
            duplicates = sorted(
                language_id
                for language_id in set(language_ids)
                if language_ids.count(language_id) > 1
            )
            if duplicates:
                names = ", ".join(duplicates)
                raise RegistryError(
                    f"editorLanguageIds.{editor}.{filetype}: duplicate language ids: {names}"
                )


def _validate_step(
    step: dict[str, Any],
    phase: str,
    owner: str,
    adapters: dict[str, Any],
    config_policies: dict[str, Any],
    dispatch_functions: dict[str, str],
    allowed_step_phases: set[str],
) -> None:
    adapter = step["adapter"]
    step_phase = str(step.get("phase", phase))
    if adapter not in adapters:
        raise RegistryError(f"{owner}.{phase}: unknown adapter: {adapter}")
    if adapters[adapter].get("kind") != "shell-function":
        raise RegistryError(
            f"{owner}.{phase}: adapter is not executable by shell dispatch: {adapter}"
        )
    if adapter not in dispatch_functions:
        raise RegistryError(
            f"{owner}.{phase}: adapter is not dispatched by shell entrypoint: {adapter}"
        )
    declared_function = str(adapters[adapter]["function"])
    dispatch_function = dispatch_functions[adapter]
    if declared_function != dispatch_function:
        raise RegistryError(
            f"{owner}.{phase}: adapter dispatch function mismatch for {adapter}: "
            f"registry declares {declared_function}, shell dispatch calls {dispatch_function}"
        )
    if "config" in step and step["config"] not in config_policies:
        raise RegistryError(f"{owner}.{phase}: unknown config policy: {step['config']}")
    if step.get("requiresConfigMatch") is True and "config" not in step:
        raise RegistryError(f"{owner}.{phase}: requiresConfigMatch requires a config policy")
    if step_phase not in _PHASES:
        raise RegistryError(f"{owner}.{phase}: unknown phase: {step.get('phase')}")
    if step_phase not in allowed_step_phases:
        expected = ", ".join(sorted(allowed_step_phases))
        raise RegistryError(
            f"{owner}.{phase}: invalid step phase {step_phase!r}; expected one of {expected}"
        )
    if phase == "lint":
        execution_scope = adapters[adapter].get("executionScope")
        if execution_scope not in _AUTOMATIC_LINT_SCOPES:
            expected = ", ".join(sorted(_AUTOMATIC_LINT_SCOPES))
            actual = execution_scope if isinstance(execution_scope, str) else "missing"
            raise RegistryError(
                f"{owner}.{phase}: automatic lint adapter {adapter} has "
                f"executionScope {actual!r}; expected one of {expected}"
            )


def load_registry(path: Path | None = None) -> dict[str, Any]:
    """Load and validate a Checkrun tooling registry.

    This is the small Python facade used by Checkrun's own tests and CLIs. It is
    intentionally stricter than JSON Schema alone because registry correctness
    depends on cross-object facts: selectors must reference declared filetypes,
    selected adapters must exist in shell dispatch, and downstream-specific keys
    must never become policy.
    """

    registry_path = path or Path(os.environ.get("CHECKRUN_REGISTRY", _REGISTRY_PATH))
    if not registry_path.is_absolute():
        registry_path = Path.cwd() / registry_path
    registry = _load_json(registry_path)
    schema = _load_json(_REGISTRY_SCHEMA_PATH)
    if not isinstance(registry, dict):
        raise RegistryError("registry root must be an object")
    if not isinstance(schema, dict):
        raise RegistryError("registry schema root must be an object")
    # Surface downstream ownership mistakes with a direct message before generic
    # additionalProperties validation turns them into a bland "unknown key".
    if _DOWNSTREAM_KEYS.intersection(registry):
        keys = ", ".join(sorted(_DOWNSTREAM_KEYS.intersection(registry)))
        raise RegistryError(f"downstream-specific registry keys are not allowed: {keys}")
    _validate_shape(registry, schema)
    _validate_invariants(registry)
    return registry


def _extension(path: Path) -> str:
    name = path.name
    if "." not in name or name.startswith(".") and name.count(".") == 1:
        return ""
    return name.rsplit(".", 1)[1]


def _abs_path(path: str) -> Path:
    return Path(path).expanduser().resolve(strict=False)


def _is_text(path: Path) -> bool:
    try:
        with path.open("rb") as file:
            chunk = file.read(1024)
    except OSError:
        return False
    return b"\0" not in chunk


def _infer_filetype(path: Path, registry: dict[str, Any]) -> str | None:
    # Match order mirrors the spec and editor expectations. Filename wins before
    # extension so files such as CMakeLists.txt and Dockerfile are stable even
    # when they contain dots or suffixes that would otherwise look generic.
    filetypes = registry["filetypes"]
    name = path.name
    ext = _extension(path)

    if name in filetypes["filename"]:
        return str(filetypes["filename"][name])
    if ext and ext in filetypes["extension"]:
        return str(filetypes["extension"][ext])

    for item in filetypes["patterns"]:
        if item.get("extensionlessOnly") is True and ext:
            continue
        # Most custom filetype patterns are basename globs, but a few safe
        # config syntaxes are identified by a narrow path shape rather than a
        # unique basename. Reusing the same candidate forms as path-scoped tool
        # matching keeps inference, explain, plan, and dispatch aligned.
        if _path_pattern_matches(path, [item["pattern"]]):
            return str(item["filetype"])

    # Shebang probing is intentionally last and text-only. Extensionless binary
    # files should remain unknown without leaking null bytes or warnings through
    # shell command substitution in hook paths.
    if ext or not path.is_file() or not _is_text(path):
        return None
    try:
        first = path.read_text(encoding="utf-8", errors="ignore").splitlines()[0]
    except (IndexError, OSError):
        return None
    if not first.startswith("#!"):
        return None
    # Shebang rules in registry.json are evaluated in document order and the
    # first match wins. Order matters because narrower interpreters (e.g. zsh)
    # must appear before broader matchers like containsAny=["bash","/sh"], which
    # would otherwise capture `#!/usr/bin/env zsh` via the trailing "sh".
    for item in filetypes["shebangs"]:
        if "contains" in item and item["contains"] in first:
            return str(item["filetype"])
        if "containsAny" in item and any(needle in first for needle in item["containsAny"]):
            return str(item["filetype"])
    return None


def _path_pattern_matches(path: Path, patterns: list[str]) -> bool:
    if not patterns:
        return True
    # Keep path-scoped tools identical between explain, plan, and execution.
    # Checking absolute, cwd-relative, and basename forms preserves old explain
    # behavior while letting shell callers pass either absolute or relative args.
    candidates = {path.as_posix(), path.name}
    try:
        candidates.add(path.relative_to(Path.cwd()).as_posix())
    except ValueError:
        pass
    return any(
        fnmatch.fnmatchcase(candidate, pattern) for candidate in candidates for pattern in patterns
    )


def _selector_matches(path: Path, filetype: str | None, selector: dict[str, Any]) -> bool:
    # Filetype inference is the only path-to-language decision point. Selectors
    # intentionally consume that normalized answer instead of carrying their own
    # filename/extension/pattern matchers, which would let execution drift from
    # editor capabilities and `checkrun explain`.
    return bool(filetype and filetype in selector.get("filetypes", []))


def _skipped_record(step: dict[str, Any], reason: str, **details: Any) -> dict[str, Any]:
    # Renamed from `_skip` to read as a record constructor instead of a verb. No
    # side effects: returns a fresh dict tagged as skipped, preserving the
    # original step's fields so explain/plan output stays explainable.
    skipped = dict(step)
    skipped["skipped"] = True
    skipped["reason"] = reason
    skipped.update(details)
    return skipped


def _config_root() -> Path:
    # Resolving roots before adapter execution protects tools that cd or
    # discover config from process cwd. Shell entrypoints export their resolved
    # value so planning and execution agree; direct `checkrun plan/explain`
    # callers use the same default here.
    value = os.environ.get("CHECKRUN_CONFIG_DIR")
    if not value:
        value = str(Path.home() / ".config/checkrun")
    value = os.path.expandvars(os.path.expanduser(value))
    path = Path(value)
    if not path.is_absolute():
        path = Path.cwd() / path
    return path.resolve(strict=False)


def _walk_config(dir_path: Path, filename: str) -> Path | None:
    # Project-local policy must win over personal fallback policy. Walking from
    # the target file directory also avoids long-lived editor/agent cwd leaking
    # into config selection.
    #
    # NOTE: the walk is intentionally unbounded — it ascends to the filesystem
    # root. That mirrors how project tools (ruff, biome, …) discover their own
    # configs, but it also means a stray config file at $HOME (e.g.
    # ~/.shellcheckrc) will be picked up by ANY file under $HOME that has no
    # closer project config. If you want personal fallback policy, prefer
    # putting it under $CHECKRUN_CONFIG_DIR so the registry can make
    # the source explicit instead of relying on the walk's accidental reach.
    current = dir_path.resolve(strict=False)
    previous: Path | None = None
    while current != previous:
        candidate = current / filename
        if candidate.is_file():
            return candidate.resolve(strict=False)
        if current.parent == current:
            break
        previous = current
        current = current.parent
    return None


def _lookup_path(data: Any, query: list[str]) -> Any:
    node = data
    for part in query:
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def _probe_contains(path: Path, contains: dict[str, Any]) -> bool:
    # Some policy files are multiplexed. A bare pyproject.toml should not disable
    # the Ruff fallback unless it actually contains Ruff policy.
    try:
        if contains["format"] == "toml":
            data = tomllib.loads(path.read_text(encoding="utf-8"))
        elif contains["format"] == "json":
            data = json.loads(path.read_text(encoding="utf-8"))
        else:
            return False
    except (OSError, JSONDecodeError, tomllib.TOMLDecodeError):
        return False
    return _lookup_path(data, [str(item) for item in contains["query"]]) is not None


def _resolve_config(
    registry: dict[str, Any],
    policy_name: str | None,
    path: Path,
) -> dict[str, Any]:
    # The registry decides which config source applies; adapters still decide
    # how to spell that source on each tool's CLI. This keeps the JSON model
    # small while preventing format/lint explainability from drifting.
    if not policy_name:
        return {"source": "native"}
    policy = registry["configPolicies"][policy_name]
    file_dir = path.parent
    for probe in policy.get("project", []):
        found = _walk_config(file_dir, probe["file"])
        if not found:
            continue
        if "contains" in probe and not _probe_contains(found, probe["contains"]):
            continue
        if policy.get("selfConfigGuard") is True and found.resolve(strict=False) == path.resolve(
            strict=False
        ):
            return {"policy": policy_name, "source": "native", "path": str(found)}
        return {"policy": policy_name, "source": "project", "path": str(found)}

    fallback = policy.get("fallback")
    if fallback:
        root = _config_root()
        candidate = (root / fallback["file"]).resolve(strict=False)
        if candidate.is_file():
            if policy.get("selfConfigGuard") is True and candidate == path.resolve(strict=False):
                return {"policy": policy_name, "source": "native", "path": str(candidate)}
            return {"policy": policy_name, "source": "fallback", "path": str(candidate)}

    if policy.get("native") == "none":
        return {"policy": policy_name, "source": "none"}
    return {"policy": policy_name, "source": "native"}


def resolve_config(
    registry: dict[str, Any],
    policy_name: str,
    file: Path | str,
) -> dict[str, Any]:
    """Resolve one registry config policy for a Checkrun-owned caller.

    `verify.py` runs project-scope tools outside the automatic lint plan, but
    those tools should still share the same project-vs-fallback config policy
    vocabulary. Keeping this small facade here avoids a second config walk just
    because the execution phase is verify instead of lint.
    """

    return _resolve_config(registry, policy_name, _abs_path(str(file)))


# Cache parsed ignore-file pattern lists per (config_dir, filename) so repeated
# `_ignore_match` calls within one planner invocation don't re-stat and re-parse
# the same files. Lint mode does four calls per file (lint/spell/schema/tool),
# so even single-file invocations benefit; the batch entrypoint that plans
# multiple files in one Python process gains an extra Nx multiplier on top.
# Sentinel `None` means "stat'd, file does not exist" (so we don't re-stat);
# missing key means "not yet probed".
_IGNORE_PATTERNS_CACHE: dict[tuple[str, str], list[str] | None] = {}


def _load_ignore_patterns(source: Path) -> list[str] | None:
    key = (str(source.parent), source.name)
    if key in _IGNORE_PATTERNS_CACHE:
        return _IGNORE_PATTERNS_CACHE[key]
    if not source.is_file():
        _IGNORE_PATTERNS_CACHE[key] = None
        return None
    try:
        lines = source.read_text(encoding="utf-8").splitlines()
    except OSError:
        _IGNORE_PATTERNS_CACHE[key] = None
        return None
    patterns: list[str] = []
    for raw in lines:
        pattern = raw.strip()
        if not pattern or pattern.startswith("#"):
            continue
        patterns.append(pattern)
    _IGNORE_PATTERNS_CACHE[key] = patterns
    return patterns


def _ignore_match(path: Path, config: Path, phase: str) -> dict[str, Any]:
    # Two filenames per phase: the shared "ignore" applies to every phase,
    # plus the phase-specific override (e.g. "lint-ignore"). Order matches the
    # original implementation so a generic `ignore` match still wins over a
    # phase-specific one for the same pattern, but reporting now uses the cache
    # rather than re-reading files.
    str_path = str(path)
    for filename in ("ignore", _PHASE_IGNORE_FILES.get(phase, f"{phase}-ignore")):
        source = config / filename
        patterns = _load_ignore_patterns(source)
        if patterns is None:
            continue
        for pattern in patterns:
            if fnmatch.fnmatchcase(str_path, pattern):
                return {"ignored": True, "source": str(source), "pattern": pattern}
    return {"ignored": False}


def _schema_associations(path: Path) -> list[dict[str, Any]]:
    # Schema association policy remains outside the tooling registry. The plan
    # reports matching associations for explainability, but the association file
    # itself is still owned by dotfiles/project policy.
    schemas_dir = _CHECKRUN_ROOT / "lib/checkrun/schemas"
    sys.path.insert(0, str(schemas_dir))
    try:
        import schema_policy  # type: ignore
    except ImportError:
        return []

    policy_path = schema_policy.policy_path()
    if not policy_path.is_file():
        return []
    try:
        policy = schema_policy.load_json(policy_path)
    except Exception:
        return []

    result = []
    for association in schema_policy.matching_associations(policy, path):
        result.append(
            {
                "name": association.get("name"),
                "format": association.get("format"),
                "schema": str(schema_policy.schema_path(policy, association)),
                "source": schema_policy.schema_url(policy, association, prefer_source=True),
                "enforce": association.get("enforce") is True,
            }
        )
    return result


def _step_key(step: dict[str, Any], default_phase: str) -> tuple[Any, ...]:
    # A missing `phase` means "the phase of the selector that contained this
    # step." Dedupe has to compare that normalized meaning, not the raw JSON
    # spelling, otherwise an explicit `"phase": "lint"` copy can run beside an
    # implicit lint step.
    return (
        str(step.get("phase", default_phase)),
        step.get("tool"),
        step.get("adapter"),
        step.get("config"),
        step.get("requiresConfigMatch") is True,
        tuple(step.get("pathPatterns", [])),
    )


def _planned_step(
    registry: dict[str, Any],
    path: Path,
    step: dict[str, Any],
    default_phase: str,
) -> dict[str, Any]:
    phase = str(step.get("phase", default_phase))
    planned = {
        "phase": phase,
        "tool": step["tool"],
        "adapter": step["adapter"],
        "config": _resolve_config(registry, step.get("config"), path),
    }
    if step.get("requiresConfigMatch") is True:
        planned["requiresConfigMatch"] = True
    if "pathPatterns" in step:
        planned["pathPatterns"] = list(step["pathPatterns"])
    return planned


def _collect_steps(
    registry: dict[str, Any],
    path: Path,
    filetype: str | None,
    phase: str,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    # Cross-cutting lint steps intentionally precede backend tool lint so
    # spelling/schema behavior remains independent of language-specific ignores.
    # Exact duplicate dedupe lets overlapping selectors compose without running
    # the same adapter twice, while distinct steps remain visible in order.
    steps: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []
    seen: set[tuple[Any, ...]] = set()
    if phase == "lint":
        for step in registry.get("crossCutting", {}).get("lint", []):
            key = _step_key(step, "lint")
            if key not in seen:
                steps.append(_planned_step(registry, path, step, "lint"))
                seen.add(key)
    for selector in registry["selectors"]:
        if not _selector_matches(path, filetype, selector):
            continue
        for step in selector.get(phase, []):
            planned = _planned_step(registry, path, step, phase)
            if not _path_pattern_matches(path, step.get("pathPatterns", [])):
                skipped.append(
                    _skipped_record(
                        planned,
                        "path-pattern",
                        patterns=list(step.get("pathPatterns", [])),
                    )
                )
                continue
            if (
                step.get("requiresConfigMatch") is True
                and planned["config"].get("source") == "none"
            ):
                # Some tools are useful only after a config policy has found
                # real project metadata. Keeping that gate in the planner makes
                # `plan`, `explain`, and shell execution describe the same
                # skip instead of hiding it inside one adapter.
                skipped.append(_skipped_record(planned, "missing-config"))
                continue
            key = _step_key(step, phase)
            if key in seen:
                continue
            steps.append(planned)
            seen.add(key)
    return steps, skipped


def _plan_file(registry: dict[str, Any], file_arg: str, phase: str | None = None) -> dict[str, Any]:
    # Planning inspects local files and config only; it never executes tools.
    # Shell entrypoints consume this as their policy answer and keep adapter
    # invocation separate.
    path = _abs_path(file_arg)
    filetype = _infer_filetype(path, registry)
    phases = [phase] if phase else ["format", "lint"]
    item: dict[str, Any] = {
        "path": str(path),
        "exists": path.is_file(),
        "filetype": filetype,
    }
    for plan_phase in phases:
        if plan_phase == "format":
            config = _config_root()
            ignored = _ignore_match(path, config, "format")
            candidate_steps, skipped = (
                _collect_steps(registry, path, filetype, "format") if path.is_file() else ([], [])
            )
            if ignored["ignored"]:
                steps = []
                skipped.extend(
                    _skipped_record(step, "phase-ignore", ignore=ignored)
                    for step in candidate_steps
                )
            else:
                steps = candidate_steps
            item["format"] = {
                "ignored": ignored["ignored"],
                "ignore": ignored if ignored["ignored"] else None,
                "steps": steps,
                "skipped": skipped,
                "configDir": str(config),
            }
        elif plan_phase == "lint":
            config = _config_root()
            lint_ignore = _ignore_match(path, config, "lint")
            spell_ignore = _ignore_match(path, config, "spell")
            schema_ignore = _ignore_match(path, config, "schema")
            tool_ignore = _ignore_match(path, config, "tool")
            all_steps, skipped = (
                _collect_steps(registry, path, filetype, "lint") if path.is_file() else ([], [])
            )
            steps = []
            for step in all_steps:
                if lint_ignore["ignored"]:
                    skipped.append(_skipped_record(step, "lint-ignore", ignore=lint_ignore))
                elif step["phase"] == "spell" and spell_ignore["ignored"]:
                    skipped.append(_skipped_record(step, "phase-ignore", ignore=spell_ignore))
                elif step["phase"] == "schema" and schema_ignore["ignored"]:
                    skipped.append(_skipped_record(step, "phase-ignore", ignore=schema_ignore))
                elif step["phase"] in {"lint", "tool"} and tool_ignore["ignored"]:
                    skipped.append(_skipped_record(step, "phase-ignore", ignore=tool_ignore))
                else:
                    steps.append(step)
            schemas = (
                []
                if schema_ignore["ignored"] or lint_ignore["ignored"] or not path.is_file()
                else _schema_associations(path)
            )
            item["lint"] = {
                "ignored": lint_ignore["ignored"],
                "ignore": lint_ignore if lint_ignore["ignored"] else None,
                "phases": {
                    "spell": {
                        "ignored": spell_ignore["ignored"],
                        "ignore": spell_ignore if spell_ignore["ignored"] else None,
                    },
                    "schema": {
                        "ignored": schema_ignore["ignored"],
                        "ignore": schema_ignore if schema_ignore["ignored"] else None,
                    },
                    "tool": {
                        "ignored": tool_ignore["ignored"],
                        "ignore": tool_ignore if tool_ignore["ignored"] else None,
                    },
                },
                "steps": steps,
                "skipped": skipped,
                "schemas": schemas,
                "configDir": str(config),
            }
    return item


def plan(registry: dict[str, Any], files: list[str], phase: str | None = None) -> dict[str, Any]:
    """Return the versioned public plan JSON payload for `files`.

    Downstream callers should normally obtain this through
    `checkrun plan --json`; keeping the same builder available here lets tests
    verify the CLI and interpreter without maintaining a second expected shape.
    """

    if phase is not None and phase not in _PLAN_PHASES:
        expected = ", ".join(sorted(_PLAN_PHASES))
        raise RegistryError(f"unknown plan phase {phase!r}; expected one of {expected}")
    return {
        "version": 1,
        "files": [_plan_file(registry, file, phase) for file in files],
    }


def capabilities(registry: dict[str, Any]) -> dict[str, Any]:
    """Return the versioned public capabilities JSON projection."""

    # Capabilities are an integration projection, not another policy source.
    # Neovim maps these generic filetypes to its local formatter/linter names.
    #
    # Lint key presence is intentional here. A selector may use `lint: []` to
    # declare "cross-cutting-only" lint support for a filetype, such as plain
    # text spell checking, without inventing a synthetic no-op adapter. Formatting
    # still requires real steps because there is no cross-cutting formatter phase.
    format_filetypes: set[str] = set()
    lint_filetypes: set[str] = set()
    for selector in registry["selectors"]:
        selector_filetypes = set(selector.get("filetypes", []))
        if selector.get("format"):
            format_filetypes.update(selector_filetypes)
        if "lint" in selector:
            lint_filetypes.update(selector_filetypes)
    custom = registry["filetypes"]
    return {
        "version": 2,
        "editorLanguageIds": {
            editor: {
                filetype: list(language_ids) for filetype, language_ids in sorted(aliases.items())
            }
            for editor, aliases in sorted(registry["editorLanguageIds"].items())
        },
        "filetypes": {
            "format": sorted(format_filetypes),
            "lint": sorted(lint_filetypes),
            "custom": {
                "filename": dict(sorted(custom["filename"].items())),
                "extension": dict(sorted(custom["extension"].items())),
                "patterns": sorted(custom["patterns"], key=lambda item: item["pattern"]),
            },
        },
    }


def explain_items(registry: dict[str, Any], files: list[str]) -> list[dict[str, Any]]:
    """Return the public JSON payload used by `checkrun explain --json`."""

    items = []
    for file in files:
        item = _plan_file(registry, file)
        fmt = item["format"]
        lint = item["lint"]
        items.append(
            {
                "path": item["path"],
                "exists": item["exists"],
                "filetype": item["filetype"],
                "format": {
                    "ignored": fmt["ignored"],
                    "ignore": fmt["ignore"],
                    "skipped": fmt["skipped"],
                    "tools": [
                        {
                            "tool": step["tool"],
                            "adapter": step["adapter"],
                            "config": step.get("config"),
                        }
                        for step in fmt["steps"]
                    ],
                    "configDir": fmt["configDir"],
                },
                "lint": {
                    "ignored": lint["ignored"],
                    "ignore": lint["ignore"],
                    "phases": lint["phases"],
                    "skipped": lint["skipped"],
                    "tools": [
                        {
                            "tool": step["tool"],
                            "adapter": step["adapter"],
                            "phase": step["phase"],
                            "config": step.get("config"),
                        }
                        for step in lint["steps"]
                        if step["phase"] in {"lint", "tool"}
                    ],
                    "schemas": lint["schemas"],
                    "configDir": lint["configDir"],
                },
            }
        )
    return items


def _print_human(items: list[dict[str, Any]]) -> None:
    for item in items:
        print(item["path"])
        print(f"  exists: {str(item['exists']).lower()}")
        print(f"  filetype: {item.get('filetype') or 'unknown'}")
        fmt = item["format"]
        if fmt["ignored"]:
            ignore = fmt["ignore"]
            print(f"  format: ignored by {ignore['source']} ({ignore['pattern']})")
        else:
            tools = ", ".join(tool["tool"] for tool in fmt["tools"]) or "none"
            print(f"  format: {tools}")
        lint = item["lint"]
        if lint["ignored"]:
            ignore = lint["ignore"]
            print(f"  lint: ignored by {ignore['source']} ({ignore['pattern']})")
        else:
            tools = ", ".join(tool["tool"] for tool in lint["tools"]) or "none"
            schema_names = (
                ", ".join(str(schema.get("name")) for schema in lint["schemas"]) or "none"
            )
            print(f"  lint tools: {tools}")
            print(f"  schemas: {schema_names}")


def _shell_plan_records(
    registry: dict[str, Any], phase: str, files: list[str]
) -> list[list[bytes]]:
    """Return per-input-file NUL-record blobs for the shell dispatch protocol.

    One blob per input file, in the same order as `files`. Each blob is the
    serialized form of every plan step for that file (already-NUL-delimited);
    an empty blob means "no steps planned for this file" (ignored / unsupported
    / no matching selectors). The single-stream and per-file-output modes
    below both use this builder so the on-disk byte format never drifts.
    """

    planned = plan(registry, files, phase)
    blobs: list[list[bytes]] = []
    for item in planned["files"]:
        chunks: list[bytes] = []
        phase_data = item[phase]
        if not phase_data["ignored"]:
            for step in phase_data["steps"]:
                config = step.get("config", {})
                fields = [
                    item["path"],
                    item.get("filetype") or "",
                    step["phase"],
                    step["adapter"],
                    config.get("source", ""),
                    config.get("path", ""),
                ]
                # NUL-delimited because paths may legally contain spaces, tabs,
                # or newlines. Shell callers read from a temp file rather than
                # command substitution since Bash variables cannot safely carry
                # NUL bytes.
                for field in fields:
                    chunks.append(str(field).encode("utf-8", "surrogateescape"))
                    chunks.append(b"\0")
        blobs.append(chunks)
    return blobs


def _print_shell_plan(registry: dict[str, Any], phase: str, files: list[str]) -> None:
    for blob in _shell_plan_records(registry, phase, files):
        for chunk in blob:
            sys.stdout.buffer.write(chunk)


def _write_shell_plan_dir(
    registry: dict[str, Any], phase: str, files: list[str], out_dir: Path
) -> None:
    """Write per-file plans into `out_dir` as `<index>.plan`.

    Files are numbered by input order so Bash callers know the mapping without
    a side manifest. Empty plans (no steps for that file) still produce a
    zero-byte `<index>.plan`; callers check `[ -s "$plan" ]` to short-circuit
    the dispatch loop the same way they do with the single-file protocol.
    """

    out_dir.mkdir(parents=True, exist_ok=True)
    for index, blob in enumerate(_shell_plan_records(registry, phase, files)):
        target = out_dir / f"{index}.plan"
        with target.open("wb") as handle:
            for chunk in blob:
                handle.write(chunk)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    raw_parser = subparsers.add_parser("registry")
    raw_parser.add_argument("--json", action="store_true", help="emit registry JSON")

    cap_parser = subparsers.add_parser("capabilities")
    cap_parser.add_argument("--json", action="store_true", help="emit capabilities JSON")

    explain_parser = subparsers.add_parser("explain")
    explain_parser.add_argument("--json", action="store_true", help="emit JSON")
    explain_parser.add_argument("files", nargs="*")

    plan_parser = subparsers.add_parser("plan")
    plan_parser.add_argument("--json", action="store_true", help="emit JSON")
    plan_parser.add_argument("--phase", choices=sorted(_PLAN_PHASES))
    plan_parser.add_argument("files", nargs="*")

    # Private execution transport for Bash callers. `bin/checkrun` does not
    # expose this command; integrations should use the versioned JSON from
    # `checkrun plan --json`.
    shell_parser = subparsers.add_parser(
        "shell-plan",
        help="private shell transport for Checkrun entrypoints",
    )
    shell_parser.add_argument("--phase", choices=sorted(_PLAN_PHASES), required=True)
    # --output-dir batches multiple files into one Python invocation. The
    # planner writes `<index>.plan` per input file (input order) into the
    # directory; the single-stream stdout path stays unchanged so existing
    # single-file callers do not have to migrate.
    shell_parser.add_argument("--output-dir")
    shell_parser.add_argument("files", nargs="*")

    args = parser.parse_args(argv)
    registry = load_registry()

    if args.command == "registry":
        if not args.json:
            parser.error("registry requires --json")
        print(json.dumps(registry, indent=2, sort_keys=True))
        return 0
    if args.command == "capabilities":
        if not args.json:
            parser.error("capabilities requires --json")
        print(json.dumps(capabilities(registry), indent=2, sort_keys=True))
        return 0
    if args.command == "explain":
        if not args.files:
            parser.error("at least one file is required")
        items = explain_items(registry, args.files)
        if args.json:
            print(json.dumps(items, separators=(",", ":"), sort_keys=True))
        else:
            _print_human(items)
        return 0
    if args.command == "plan":
        if not args.json:
            parser.error("plan requires --json")
        print(
            json.dumps(
                plan(registry, args.files, args.phase), separators=(",", ":"), sort_keys=True
            )
        )
        return 0
    if args.command == "shell-plan":
        if args.output_dir:
            _write_shell_plan_dir(registry, args.phase, args.files, Path(args.output_dir))
        else:
            _print_shell_plan(registry, args.phase, args.files)
        return 0
    raise AssertionError(args.command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RegistryError as exc:
        print(f"checkrun registry: {exc}", file=sys.stderr)
        raise SystemExit(2) from None
