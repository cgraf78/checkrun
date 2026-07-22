#!/usr/bin/env python3
"""Validate config files with the shared Checkrun schema policy."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from json import JSONDecodeError
from pathlib import Path
from typing import Any

import schema_policy


@dataclass(frozen=True)
class Diagnostic:
    path: str
    message: str
    source: str = "json-schema"
    severity: str = "error"
    code: str | None = None
    line: int = 1
    col: int = 1

    def as_json(self) -> str:
        data: dict[str, Any] = {
            "path": self.path,
            "line": self.line,
            "col": self.col,
            "severity": self.severity,
            "message": self.message,
            "source": self.source,
        }
        if self.code:
            data["code"] = self.code
        return json.dumps(data, separators=(",", ":"))

    def as_text(self) -> str:
        return f"{self.path}:{self.line}:{self.col}: {self.message}"


class SkipValidation(Exception):
    """Raised when optional parser dependencies are unavailable."""


def _missing_optional_deps() -> list[str]:
    missing: list[str] = []
    if importlib.util.find_spec("jsonschema") is None:
        missing.append("jsonschema")
    if importlib.util.find_spec("yaml") is None:
        missing.append("PyYAML")
    if importlib.util.find_spec("tomllib") is None and importlib.util.find_spec("tomli") is None:
        missing.append("tomli")
    return missing


def _ensure_optional_deps() -> None:
    missing = _missing_optional_deps()
    if not missing or os.environ.get("CHECKRUN_SCHEMA_LINT_UV_BOOTSTRAP") == "1":
        return

    uv = shutil.which("uv")
    if uv is None:
        # Without uv we cannot self-bootstrap; without the optional deps we also
        # cannot validate. Emit a stderr notice instead of silently producing
        # zero diagnostics — a "schema-lint passes" result on a lean host
        # previously looked indistinguishable from a real green run.
        #
        # schema-lint runs as a separate process per linted file, so this fires
        # once per invocation, not once per session. That's noisy on truly
        # lean hosts but is preferable to silent green: a user who can't
        # install uv or jsonschema gets a clear, repeated signal that the
        # phase is unenforced. Future batching of schema-lint would naturally
        # collapse the notice the same way the planner batching does.
        print(
            "schema-lint: optional dependencies missing and uv unavailable; "
            f"schema validation skipped (missing: {', '.join(missing)})",
            file=sys.stderr,
        )
        return

    env = os.environ.copy()
    env["CHECKRUN_SCHEMA_LINT_UV_BOOTSTRAP"] = "1"
    command = [
        uv,
        "run",
        "--quiet",
        "--with",
        "jsonschema",
        "--with",
        "PyYAML",
        "--with",
        "tomli",
        "python",
        str(Path(__file__).resolve()),
        *sys.argv[1:],
    ]
    raise SystemExit(subprocess.call(command, env=env))


def _parse(path: Path, fmt: str) -> Any:
    if fmt == "json":
        return schema_policy.load_json(path)
    if fmt == "yaml":
        try:
            import yaml  # type: ignore[import-not-found]
        except ModuleNotFoundError as exc:
            raise SkipValidation from exc
        try:
            with path.open("r", encoding="utf-8") as file:
                return yaml.safe_load(file)
        except yaml.YAMLError as exc:
            raise ValueError(exc) from exc
    if fmt == "toml":
        try:
            import tomllib
        except ModuleNotFoundError as exc:
            try:
                import tomli as tomllib  # type: ignore[import-not-found,no-redef]
            except ModuleNotFoundError:
                raise SkipValidation from exc

        return tomllib.loads(path.read_text(encoding="utf-8"))
    raise ValueError(f"unsupported schema format: {fmt}")


def _json_path(error: Any) -> str:
    parts = [str(part) for part in error.absolute_path]
    return ".".join(parts) if parts else "<root>"


def _validate_with_schema(
    path: Path,
    data: Any,
    schema_path: Path,
    name: str,
) -> list[Diagnostic]:
    # Normal file validation and policy bootstrap validation both need the
    # same jsonschema error shaping. Keeping that in one helper prevents the
    # self-schema path from drifting from ordinary association validation.
    try:
        import jsonschema  # type: ignore[import-not-found]
    except ModuleNotFoundError:
        return []

    diagnostics: list[Diagnostic] = []
    if not schema_path.is_file():
        return [
            Diagnostic(
                path=str(path),
                code=name,
                message=f"{name}: schema file not found: {schema_path}",
            )
        ]
    try:
        schema = schema_policy.load_json(schema_path)
        validator_cls = jsonschema.validators.validator_for(schema)
        validator_cls.check_schema(schema)
        validator = validator_cls(schema)
        for error in sorted(validator.iter_errors(data), key=lambda item: list(item.path)):
            diagnostics.append(
                Diagnostic(
                    path=str(path),
                    code=name,
                    message=f"{name}: {_json_path(error)}: {error.message}",
                )
            )
    except jsonschema.exceptions.SchemaError as exc:
        diagnostics.append(
            Diagnostic(
                path=str(path),
                code=name,
                message=f"{name}: invalid schema {schema_path}: {exc.message}",
            )
        )
    except (JSONDecodeError, OSError, RuntimeError, ValueError) as exc:
        diagnostics.append(
            Diagnostic(
                path=str(path),
                code=name,
                message=f"{name}: {exc}",
            )
        )
    return diagnostics


def _validate(policy: dict[str, Any], path: Path) -> list[Diagnostic]:
    diagnostics: list[Diagnostic] = []
    for association in schema_policy.matching_associations(policy, path):
        name = str(association.get("name", "schema"))
        fmt = str(association.get("format", "")).lower()
        schema_path = schema_policy.schema_path(policy, association)
        try:
            data = _parse(path, fmt)
            diagnostics.extend(_validate_with_schema(path, data, schema_path, name))
        except SkipValidation:
            continue
        except (JSONDecodeError, OSError, RuntimeError, ValueError) as exc:
            diagnostics.append(
                Diagnostic(
                    path=str(path),
                    code=name,
                    message=f"{name}: {exc}",
                )
            )
    return diagnostics


def _is_same_file(left: Path, right: Path) -> bool:
    # Callers can pass the policy path as relative, absolute, or expanded from
    # HOME. Resolve both sides so the bootstrap check cannot be bypassed by
    # spelling the same file differently.
    try:
        return left.resolve() == right.resolve()
    except OSError:
        return left == right


def _validate_policy_file(
    policy_path: Path,
    policy: dict[str, Any],
    path: Path,
) -> list[Diagnostic]:
    if not _is_same_file(path, policy_path):
        return []

    # A policy file registers itself for editor visibility, but the validator
    # cannot rely on that entry when the file itself is being edited. A damaged
    # association list would otherwise disable the very check meant to catch
    # policy-shape mistakes. The policy instance may live in an integration or
    # app repo; checkrun owns the schema for the document shape.
    schema_path = schema_policy.policy_schema_path()
    return _validate_with_schema(path, policy, schema_path, "Checkrun schema association policy")


def _run(files: list[str], *, json_output: bool) -> int:
    policy_path = schema_policy.policy_path()
    if not policy_path.is_file():
        return 0
    try:
        policy = schema_policy.load_json(policy_path)
    except (JSONDecodeError, OSError) as exc:
        diagnostic = Diagnostic(path=str(policy_path), message=f"schema policy: {exc}")
        print(diagnostic.as_json() if json_output else diagnostic.as_text())
        return 1

    if files:
        _ensure_optional_deps()

    diagnostics: list[Diagnostic] = []
    for file_arg in files:
        path = Path(file_arg)
        if not path.is_absolute():
            path = Path.cwd() / path
        if path.is_file():
            if _is_same_file(path, policy_path):
                diagnostics.extend(_validate_policy_file(policy_path, policy, path))
                continue
            diagnostics.extend(_validate(policy, path))

    for diagnostic in diagnostics:
        print(diagnostic.as_json() if json_output else diagnostic.as_text())
    return 1 if diagnostics else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit unified JSON diagnostics")
    parser.add_argument("files", nargs="*")
    args = parser.parse_args(argv)

    try:
        return _run(args.files, json_output=args.json)
    except schema_policy.PathPolicyError as exc:
        diagnostic = Diagnostic(path="", message=f"schema policy: {exc}")
        print(diagnostic.as_json() if args.json else diagnostic.as_text())
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
