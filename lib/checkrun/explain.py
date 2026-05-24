#!/usr/bin/env python3
"""Explain Checkrun formatter, linter, ignore, and schema policy decisions."""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import sys
from pathlib import Path
from typing import Any

CHECKRUN_ROOT = Path(__file__).resolve().parents[2]
CAPABILITIES_PATH = CHECKRUN_ROOT / "share/checkrun/capabilities.json"
PHASE_IGNORE_FILES = {
    "format": "format-ignore",
    "lint": "lint-ignore",
    "spell": "spell-ignore",
    "schema": "schema-ignore",
    "tool": "tool-ignore",
}


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def abs_path(path: str) -> Path:
    return Path(path).expanduser().resolve(strict=False)


def config_dir(env_name: str) -> Path:
    value = os.environ.get(env_name) or str(Path.home() / ".config/autoformat")
    return abs_path(value)


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


def extension(path: Path) -> str:
    name = path.name
    if "." not in name or name.startswith(".") and name.count(".") == 1:
        return ""
    return name.rsplit(".", 1)[1]


def classify_shell(path: Path) -> str | None:
    name = path.name
    if name in {".zshenv", ".zshrc", ".zprofile", ".zlogin", ".zlogout"}:
        return "zsh"
    if name in {".bashrc", ".bash_profile", ".profile", ".envrc", "envrc"}:
        return "bash"
    if name.startswith("envrc-"):
        return "bash"
    if not path.is_file():
        return None
    try:
        with path.open("rb") as file:
            first = file.readline(256).decode("utf-8", "ignore")
    except OSError:
        return None
    if first.startswith("#!") and "zsh" in first:
        return "zsh"
    if first.startswith("#!") and ("bash" in first or "/sh" in first):
        return "bash"
    return None


def path_matches(path: Path, selector: dict[str, Any]) -> bool:
    name = path.name
    ext = extension(path)
    if name in selector.get("filenames", []):
        return True
    if ext and ext in selector.get("extensions", []):
        return True
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in selector.get("patterns", []))


def path_pattern_matches(path: Path, patterns: list[str]) -> bool:
    if not patterns:
        return True

    candidates = {path.as_posix(), path.name}
    try:
        candidates.add(path.relative_to(Path.cwd()).as_posix())
    except ValueError:
        pass

    return any(
        fnmatch.fnmatchcase(candidate, pattern)
        for candidate in candidates
        for pattern in patterns
    )


def infer_filetype(path: Path, capabilities: dict[str, Any]) -> str | None:
    name = path.name
    ext = extension(path)
    custom = capabilities.get("sley", {}).get("customFiletypes", {})
    filename_map = custom.get("filename", {})
    extension_map = custom.get("extension", {})
    if name in filename_map:
        return filename_map[name]
    if ext in extension_map:
        return extension_map[ext]
    for item in custom.get("patterns", []):
        pattern = item.get("pattern")
        if not isinstance(pattern, str):
            continue
        if item.get("extensionlessOnly") is True and ext:
            continue
        if fnmatch.fnmatchcase(name, pattern):
            ft = item.get("filetype")
            return ft if isinstance(ft, str) else None

    ext_map = {
        "bash": "bash",
        "bzl": "bzl",
        "c": "c",
        "cc": "cpp",
        "cmake": "cmake",
        "cpp": "cpp",
        "css": "css",
        "cxx": "cpp",
        "go": "go",
        "h": "c",
        "hpp": "cpp",
        "htm": "html",
        "html": "html",
        "hxx": "cpp",
        "java": "java",
        "js": "javascript",
        "json": "json",
        "jsonc": "jsonc",
        "jsx": "javascriptreact",
        "lua": "lua",
        "md": "markdown",
        "mk": "make",
        "php": "php",
        "py": "python",
        "rb": "ruby",
        "rs": "rust",
        "sh": "sh",
        "star": "starlark",
        "toml": "toml",
        "ts": "typescript",
        "tsx": "typescriptreact",
        "yaml": "yaml",
        "yml": "yaml",
        "zsh": "zsh",
    }
    if ext in ext_map:
        return ext_map[ext]
    return classify_shell(path)


def selector_tools(path: Path, capabilities: dict[str, Any], phase: str) -> list[dict[str, Any]]:
    tools: list[dict[str, Any]] = []
    for selector in capabilities.get("selectors", []):
        if path_matches(path, selector):
            tools.extend(
                tool
                for tool in selector.get(phase, [])
                if path_pattern_matches(path, tool.get("pathPatterns", []))
            )
    return tools


def schema_associations(path: Path) -> list[dict[str, Any]]:
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


def explain_file(path_arg: str, capabilities: dict[str, Any]) -> dict[str, Any]:
    path = abs_path(path_arg)
    format_config = config_dir("CHECKRUN_AUTOFORMAT_DIR")
    lint_config = config_dir("CHECKRUN_AUTOLINT_DIR")
    format_ignore = ignore_match(path, format_config, "format")
    lint_ignore = ignore_match(path, lint_config, "lint")
    spell_ignore = ignore_match(path, lint_config, "spell")
    schema_ignore = ignore_match(path, lint_config, "schema")
    tool_ignore = ignore_match(path, lint_config, "tool")
    schemas = [] if schema_ignore["ignored"] else schema_associations(path)

    return {
        "path": str(path),
        "exists": path.is_file(),
        "filetype": infer_filetype(path, capabilities),
        "format": {
            "ignored": format_ignore["ignored"],
            "ignore": format_ignore if format_ignore["ignored"] else None,
            "tools": []
            if format_ignore["ignored"]
            else selector_tools(path, capabilities, "format"),
            "configDir": str(format_config),
        },
        "lint": {
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
            "tools": []
            if lint_ignore["ignored"] or tool_ignore["ignored"]
            else selector_tools(path, capabilities, "lint"),
            "schemas": schemas,
            "configDir": str(lint_config),
        },
    }


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
            print(f"  lint tools: {tools}")
            schema_names = (
                ", ".join(str(schema.get("name")) for schema in lint["schemas"]) or "none"
            )
            print(f"  schemas: {schema_names}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--capabilities", action="store_true", help="emit Checkrun capability metadata"
    )
    parser.add_argument("--json", action="store_true", help="emit JSON")
    parser.add_argument("files", nargs="*")
    args = parser.parse_args(argv)

    capabilities = load_json(CAPABILITIES_PATH)
    if args.capabilities:
        print(json.dumps(capabilities, indent=2, sort_keys=True))
        return 0

    if not args.files:
        parser.error("at least one file is required")

    items = [explain_file(file, capabilities) for file in args.files]
    if args.json:
        print(json.dumps(items, separators=(",", ":"), sort_keys=True))
    else:
        print_human(items)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
