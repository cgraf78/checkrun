#!/usr/bin/env python3
"""Checkrun tooling registry interpreter."""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import sys
from json import JSONDecodeError
from pathlib import Path
from typing import Any

import tomllib

CHECKRUN_ROOT = Path(__file__).resolve().parents[2]
REGISTRY_PATH = CHECKRUN_ROOT / "share/checkrun/registry.json"
REGISTRY_SCHEMA_PATH = CHECKRUN_ROOT / "share/checkrun/schemas/registry.schema.json"

# Keep phase names centralized because the registry is now the contract shared by
# shell hooks, CLI explainability, and editor integrations. If a new phase is
# introduced in only one caller, drift comes back immediately.
PHASES = {"format", "lint", "spell", "schema", "tool"}
PLAN_PHASES = {"format", "lint"}
ENV_ROOTS = {"CHECKRUN_AUTOFORMAT_DIR", "CHECKRUN_AUTOLINT_DIR"}
DOWNSTREAM_KEYS = {"sley", "nvim"}
PHASE_IGNORE_FILES = {
    "format": "format-ignore",
    "lint": "lint-ignore",
    "spell": "spell-ignore",
    "schema": "schema-ignore",
    "tool": "tool-ignore",
}


class RegistryError(RuntimeError):
    """Raised when the registry cannot be loaded or validated."""


def load_json(path: Path) -> Any:
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


def validate_shape(registry: dict[str, Any], schema: dict[str, Any]) -> None:
    _validate_schema_node(registry, schema, schema, "registry")


def validate_invariants(registry: dict[str, Any]) -> None:
    # JSON Schema can prove the document shape, but not the cross-object
    # relationships that make the registry trustworthy as a source of truth.
    # These checks are the drift guard: metadata cannot advertise an adapter,
    # config policy, or filetype that execution cannot understand.
    if DOWNSTREAM_KEYS.intersection(registry):
        keys = ", ".join(sorted(DOWNSTREAM_KEYS.intersection(registry)))
        raise RegistryError(f"downstream-specific registry keys are not allowed: {keys}")

    declared_filetypes = set(registry["filetypes"]["extension"].values())
    declared_filetypes.update(registry["filetypes"]["filename"].values())
    declared_filetypes.update(item["filetype"] for item in registry["filetypes"]["patterns"])
    declared_filetypes.update(item["filetype"] for item in registry["filetypes"]["shebangs"])

    selectors_seen: set[str] = set()
    adapters = registry["adapters"]
    config_policies = registry["configPolicies"]
    for selector in registry["selectors"]:
        selector_id = selector["id"]
        if selector_id in selectors_seen:
            raise RegistryError(f"duplicate selector id: {selector_id}")
        selectors_seen.add(selector_id)
        if DOWNSTREAM_KEYS.intersection(selector):
            keys = ", ".join(sorted(DOWNSTREAM_KEYS.intersection(selector)))
            raise RegistryError(f"{selector_id}: downstream-specific keys are not allowed: {keys}")
        for filetype in selector.get("filetypes", []):
            if filetype not in declared_filetypes:
                raise RegistryError(f"{selector_id}: undeclared filetype: {filetype}")
        for phase in ("format", "lint"):
            for step in selector.get(phase, []):
                validate_step(step, phase, selector_id, adapters, config_policies)

    for phase, steps in registry.get("crossCutting", {}).items():
        if phase not in PLAN_PHASES:
            raise RegistryError(f"unknown cross-cutting phase: {phase}")
        for step in steps:
            step_phase = str(step.get("phase", phase))
            if step_phase not in PHASES:
                raise RegistryError(f"unknown step phase: {step_phase}")
            validate_step(step, step_phase, f"crossCutting.{phase}", adapters, config_policies)

    for name, policy in config_policies.items():
        env_root = policy.get("envRoot")
        if env_root is not None and env_root not in ENV_ROOTS:
            raise RegistryError(f"{name}: unknown env root: {env_root}")

    for adapter_id, adapter in adapters.items():
        if adapter.get("kind") == "shell-function" and not adapter.get("function"):
            raise RegistryError(f"{adapter_id}: shell-function adapter requires function")

    for item in registry["filetypes"]["shebangs"]:
        has_contains = "contains" in item
        has_any = "containsAny" in item
        if has_contains == has_any:
            raise RegistryError("shebang rule must contain exactly one matcher")


def validate_step(
    step: dict[str, Any],
    phase: str,
    owner: str,
    adapters: dict[str, Any],
    config_policies: dict[str, Any],
) -> None:
    adapter = step["adapter"]
    if adapter not in adapters:
        raise RegistryError(f"{owner}.{phase}: unknown adapter: {adapter}")
    if "config" in step and step["config"] not in config_policies:
        raise RegistryError(f"{owner}.{phase}: unknown config policy: {step['config']}")
    if step.get("phase", phase) not in PHASES:
        raise RegistryError(f"{owner}.{phase}: unknown phase: {step.get('phase')}")


def load_registry(path: Path | None = None) -> dict[str, Any]:
    registry_path = path or Path(os.environ.get("CHECKRUN_REGISTRY", REGISTRY_PATH))
    if not registry_path.is_absolute():
        registry_path = Path.cwd() / registry_path
    registry = load_json(registry_path)
    schema = load_json(REGISTRY_SCHEMA_PATH)
    if not isinstance(registry, dict):
        raise RegistryError("registry root must be an object")
    if not isinstance(schema, dict):
        raise RegistryError("registry schema root must be an object")
    # Surface downstream ownership mistakes with a direct message before generic
    # additionalProperties validation turns them into a bland "unknown key".
    if DOWNSTREAM_KEYS.intersection(registry):
        keys = ", ".join(sorted(DOWNSTREAM_KEYS.intersection(registry)))
        raise RegistryError(f"downstream-specific registry keys are not allowed: {keys}")
    validate_shape(registry, schema)
    validate_invariants(registry)
    return registry


def extension(path: Path) -> str:
    name = path.name
    if "." not in name or name.startswith(".") and name.count(".") == 1:
        return ""
    return name.rsplit(".", 1)[1]


def abs_path(path: str) -> Path:
    return Path(path).expanduser().resolve(strict=False)


def _is_text(path: Path) -> bool:
    try:
        with path.open("rb") as file:
            chunk = file.read(1024)
    except OSError:
        return False
    return b"\0" not in chunk


def infer_filetype(path: Path, registry: dict[str, Any]) -> str | None:
    # Match order mirrors the spec and editor expectations. Filename wins before
    # extension so files such as CMakeLists.txt and Dockerfile are stable even
    # when they contain dots or suffixes that would otherwise look generic.
    filetypes = registry["filetypes"]
    name = path.name
    ext = extension(path)

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
        if path_pattern_matches(path, [item["pattern"]]):
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
    for item in filetypes["shebangs"]:
        if "contains" in item and item["contains"] in first:
            return str(item["filetype"])
        if "containsAny" in item and any(needle in first for needle in item["containsAny"]):
            return str(item["filetype"])
    return None


def path_pattern_matches(path: Path, patterns: list[str]) -> bool:
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


def selector_matches(path: Path, filetype: str | None, selector: dict[str, Any]) -> bool:
    name = path.name
    ext = extension(path)
    if filetype and filetype in selector.get("filetypes", []):
        return True
    if name in selector.get("filenames", []):
        return True
    if ext and ext in selector.get("extensions", []):
        return True
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in selector.get("patterns", []))


def config_root(env_name: str) -> Path:
    # Lint defaults through CHECKRUN_AUTOFORMAT_DIR because most personal policy
    # files live in one dotfiles directory. Resolving roots here, before adapter
    # execution, protects tools that cd or discover config from process cwd.
    if env_name == "CHECKRUN_AUTOLINT_DIR":
        value = os.environ.get("CHECKRUN_AUTOLINT_DIR") or os.environ.get("CHECKRUN_AUTOFORMAT_DIR")
    else:
        value = os.environ.get(env_name)
    if not value:
        value = str(Path.home() / ".config/autoformat")
    value = os.path.expandvars(os.path.expanduser(value))
    path = Path(value)
    if not path.is_absolute():
        path = Path.cwd() / path
    return path.resolve(strict=False)


def walk_config(dir_path: Path, filename: str) -> Path | None:
    # Project-local policy must win over personal fallback policy. Walking from
    # the target file directory also avoids long-lived editor/agent cwd leaking
    # into config selection.
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


def resolve_config(
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
        found = walk_config(file_dir, probe["file"])
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
    if fallback and policy.get("envRoot"):
        root = config_root(str(policy["envRoot"]))
        candidate = (root / fallback["file"]).resolve(strict=False)
        if candidate.is_file():
            if policy.get("selfConfigGuard") is True and candidate == path.resolve(strict=False):
                return {"policy": policy_name, "source": "native", "path": str(candidate)}
            return {"policy": policy_name, "source": "fallback", "path": str(candidate)}

    if policy.get("native") == "none":
        return {"policy": policy_name, "source": "none"}
    return {"policy": policy_name, "source": "native"}


def ignore_match(path: Path, config: Path, phase: str) -> dict[str, Any]:
    for filename in ("ignore", PHASE_IGNORE_FILES.get(phase, f"{phase}-ignore")):
        source = config / filename
        if not source.is_file():
            continue
        try:
            lines = source.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for raw in lines:
            pattern = raw.strip()
            if not pattern or pattern.startswith("#"):
                continue
            if fnmatch.fnmatchcase(str(path), pattern):
                return {"ignored": True, "source": str(source), "pattern": pattern}
    return {"ignored": False}


def schema_associations(path: Path) -> list[dict[str, Any]]:
    # Schema association policy remains outside the tooling registry. The plan
    # reports matching associations for explainability, but the association file
    # itself is still owned by dotfiles/project policy.
    schemas_dir = CHECKRUN_ROOT / "lib/checkrun/schemas"
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


def _step_key(step: dict[str, Any]) -> tuple[Any, ...]:
    return (
        step.get("phase"),
        step.get("tool"),
        step.get("adapter"),
        step.get("config"),
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
        "config": resolve_config(registry, step.get("config"), path),
    }
    if "pathPatterns" in step:
        planned["pathPatterns"] = list(step["pathPatterns"])
    return planned


def selected_steps(
    registry: dict[str, Any],
    path: Path,
    filetype: str | None,
    phase: str,
) -> list[dict[str, Any]]:
    # Cross-cutting lint steps intentionally precede backend tool lint so
    # spelling/schema behavior remains independent of language-specific ignores.
    # Exact duplicate dedupe lets overlapping selectors compose without running
    # the same adapter twice, while distinct steps remain visible in order.
    steps: list[dict[str, Any]] = []
    seen: set[tuple[Any, ...]] = set()
    if phase == "lint":
        for step in registry.get("crossCutting", {}).get("lint", []):
            key = _step_key(step)
            if key not in seen:
                steps.append(_planned_step(registry, path, step, "lint"))
                seen.add(key)
    for selector in registry["selectors"]:
        if not selector_matches(path, filetype, selector):
            continue
        for step in selector.get(phase, []):
            if not path_pattern_matches(path, step.get("pathPatterns", [])):
                continue
            key = _step_key(step)
            if key in seen:
                continue
            steps.append(_planned_step(registry, path, step, phase))
            seen.add(key)
    return steps


def plan_file(registry: dict[str, Any], file_arg: str, phase: str | None = None) -> dict[str, Any]:
    # Planning inspects local files and config only; it never executes tools.
    # Shell entrypoints consume this as their policy answer and keep adapter
    # invocation separate.
    path = abs_path(file_arg)
    filetype = infer_filetype(path, registry)
    phases = [phase] if phase else ["format", "lint"]
    item: dict[str, Any] = {
        "path": str(path),
        "exists": path.is_file(),
        "filetype": filetype,
    }
    for plan_phase in phases:
        if plan_phase == "format":
            config = config_root("CHECKRUN_AUTOFORMAT_DIR")
            ignored = ignore_match(path, config, "format")
            steps = (
                []
                if ignored["ignored"] or not path.is_file()
                else selected_steps(registry, path, filetype, "format")
            )
            item["format"] = {
                "ignored": ignored["ignored"],
                "ignore": ignored if ignored["ignored"] else None,
                "steps": steps,
                "configDir": str(config),
            }
        elif plan_phase == "lint":
            config = config_root("CHECKRUN_AUTOLINT_DIR")
            lint_ignore = ignore_match(path, config, "lint")
            spell_ignore = ignore_match(path, config, "spell")
            schema_ignore = ignore_match(path, config, "schema")
            tool_ignore = ignore_match(path, config, "tool")
            all_steps = (
                []
                if lint_ignore["ignored"] or not path.is_file()
                else selected_steps(registry, path, filetype, "lint")
            )
            steps = [
                step
                for step in all_steps
                if not (
                    step["phase"] == "spell"
                    and spell_ignore["ignored"]
                    or step["phase"] == "schema"
                    and schema_ignore["ignored"]
                    or step["phase"] in {"lint", "tool"}
                    and tool_ignore["ignored"]
                )
            ]
            schemas = (
                []
                if schema_ignore["ignored"] or lint_ignore["ignored"] or not path.is_file()
                else schema_associations(path)
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
                "schemas": schemas,
                "configDir": str(config),
            }
    return item


def plan(registry: dict[str, Any], files: list[str], phase: str | None = None) -> dict[str, Any]:
    return {
        "version": 1,
        "files": [plan_file(registry, file, phase) for file in files],
    }


def capabilities(registry: dict[str, Any]) -> dict[str, Any]:
    # Capabilities are an integration projection, not another policy source.
    # Neovim maps these generic filetypes to its local formatter/linter names.
    format_filetypes: set[str] = set()
    lint_filetypes: set[str] = {"text"}
    for selector in registry["selectors"]:
        selector_filetypes = set(selector.get("filetypes", []))
        if selector.get("format"):
            format_filetypes.update(selector_filetypes)
        if selector.get("format") or selector.get("lint"):
            lint_filetypes.update(selector_filetypes)
    custom = registry["filetypes"]
    return {
        "version": 2,
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
    items = []
    for file in files:
        item = plan_file(registry, file)
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


def print_human(items: list[dict[str, Any]]) -> None:
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


def print_shell_plan(registry: dict[str, Any], phase: str, files: list[str]) -> None:
    planned = plan(registry, files, phase)
    for item in planned["files"]:
        phase_data = item[phase]
        if phase_data["ignored"]:
            continue
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
            print("\t".join(str(field) for field in fields))


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
    plan_parser.add_argument("--phase", choices=sorted(PLAN_PHASES))
    plan_parser.add_argument("files", nargs="*")

    shell_parser = subparsers.add_parser("shell-plan")
    shell_parser.add_argument("--phase", choices=sorted(PLAN_PHASES), required=True)
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
            print_human(items)
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
        print_shell_plan(registry, args.phase, args.files)
        return 0
    raise AssertionError(args.command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RegistryError as exc:
        print(f"checkrun registry: {exc}", file=sys.stderr)
        raise SystemExit(2) from None
