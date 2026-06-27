#!/usr/bin/env python3
"""Explicit project verification checks for Checkrun.

`autolint` is the save-time/editor surface. This module is intentionally not
part of the registry lint plan: checks here may run at module or project scope,
touch vulnerability databases, or take long enough that editor diagnostics would
be noisy. The public entry point is `checkrun verify`.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

_DEFAULT_PATHS = ["."]
_SKIP_WALK_DIRS = {
    ".git",
    ".hg",
    ".svn",
    ".tox",
    ".venv",
    "node_modules",
    "vendor",
}


def _abs(path: str) -> Path:
    return Path(path).expanduser().resolve(strict=False)


def _nearest_go_module(start: Path) -> Path | None:
    current = start if start.is_dir() else start.parent
    previous: Path | None = None
    while current != previous:
        if (current / "go.mod").is_file():
            return current.resolve(strict=False)
        if current.parent == current:
            break
        previous = current
        current = current.parent
    return None


def _walk_go_modules(root: Path) -> list[Path]:
    modules: list[Path] = []
    if not root.is_dir():
        return modules

    # Directory arguments should mean "verify modules under here", while file
    # arguments mean "verify the nearest owning module". `os.walk` lets us skip
    # dependency/cache trees without depending on `fd` or GNU find at runtime.
    for dir_path, dir_names, file_names in os.walk(root):
        dir_names[:] = [name for name in dir_names if name not in _SKIP_WALK_DIRS]
        if "go.mod" in file_names:
            modules.append(Path(dir_path).resolve(strict=False))
    return modules


def discover_go_modules(paths: list[str]) -> list[Path]:
    modules: list[Path] = []
    seen: set[str] = set()

    for raw_path in paths or _DEFAULT_PATHS:
        path = _abs(raw_path)
        candidates: list[Path] = []
        if path.is_dir():
            candidates = _walk_go_modules(path)
            if not candidates:
                nearest = _nearest_go_module(path)
                if nearest:
                    candidates = [nearest]
        elif path.is_file():
            nearest = _nearest_go_module(path.parent)
            if nearest:
                candidates = [nearest]

        for module in candidates:
            key = str(module)
            if key not in seen:
                seen.add(key)
                modules.append(module)

    return modules


def _position_from_trace(module: Path, finding: dict[str, Any]) -> tuple[str, int, int]:
    for frame in finding.get("trace", []) or []:
        if not isinstance(frame, dict):
            continue
        position = frame.get("position")
        if not isinstance(position, dict):
            continue
        filename = position.get("filename") or position.get("file")
        if not filename:
            continue
        path = Path(str(filename))
        if not path.is_absolute():
            path = module / path
        line = position.get("line") or position.get("line_start") or 1
        col = position.get("column") or position.get("col") or 1
        return str(path.resolve(strict=False)), int(line), int(col)
    return str((module / "go.mod").resolve(strict=False)), 1, 1


def _finding_id(finding: dict[str, Any]) -> str:
    osv = finding.get("osv")
    if isinstance(osv, str):
        return osv
    if isinstance(osv, dict) and isinstance(osv.get("id"), str):
        return str(osv["id"])
    for key in ("osv_id", "id"):
        if isinstance(finding.get(key), str):
            return str(finding[key])
    return "govulncheck"


def _finding_message(finding: dict[str, Any], osv: dict[str, dict[str, Any]]) -> str:
    vuln_id = _finding_id(finding)
    summary = osv.get(vuln_id, {}).get("summary")
    if isinstance(summary, str) and summary:
        return summary
    message = finding.get("message")
    if isinstance(message, str) and message:
        return message
    fixed = finding.get("fixed_version")
    if isinstance(fixed, str) and fixed:
        return f"{vuln_id} fixed in {fixed}"
    return vuln_id


def _json_error(module: Path, message: str) -> dict[str, Any]:
    return {
        "path": str((module / "go.mod").resolve(strict=False)),
        "line": 1,
        "col": 1,
        "severity": "error",
        "code": None,
        "message": message,
        "source": "govulncheck",
    }


def _parse_govulncheck_json(module: Path, stdout: str) -> list[dict[str, Any]]:
    osv: dict[str, dict[str, Any]] = {}
    findings: list[dict[str, Any]] = []
    diagnostics: list[dict[str, Any]] = []

    for line in stdout.splitlines():
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        osv_event = event.get("osv")
        if isinstance(osv_event, dict) and isinstance(osv_event.get("id"), str):
            osv[str(osv_event["id"])] = osv_event
            continue
        finding = event.get("finding")
        if not isinstance(finding, dict):
            continue
        findings.append(finding)

    # govulncheck emits a stream, not a sorted document. Buffer findings until
    # all OSV records are known so summaries survive whichever order the tool
    # chooses for a particular run or future protocol version.
    for finding in findings:
        path, line_no, col = _position_from_trace(module, finding)
        vuln_id = _finding_id(finding)
        diagnostics.append(
            {
                "path": path,
                "line": line_no,
                "col": col,
                "severity": "error",
                "code": vuln_id,
                "message": _finding_message(finding, osv),
                "source": "govulncheck",
            }
        )

    return diagnostics


def _merge_rc(current: int, incoming: int) -> int:
    if incoming == 0:
        return current
    if current == 0:
        return incoming
    return current


def run_govulncheck(modules: list[Path], *, json_mode: bool) -> int:
    if shutil.which("govulncheck") is None:
        return 0

    rc = 0
    for module in modules:
        command = ["govulncheck"]
        if json_mode:
            command.append("-json")
        command.append("./...")

        if json_mode:
            proc = subprocess.run(
                command,
                cwd=module,
                text=True,
                capture_output=True,
                check=False,
            )
            diagnostics = _parse_govulncheck_json(module, proc.stdout)
            if proc.returncode != 0 and not diagnostics and proc.stderr.strip():
                # govulncheck's JSON stream is structured when scanning reaches
                # findings. Transport/setup failures can still arrive only on
                # stderr; surface one synthetic diagnostic so JSON callers get a
                # machine-readable failure instead of an empty non-zero run.
                diagnostics = [_json_error(module, proc.stderr.strip().splitlines()[-1])]
            for diagnostic in diagnostics:
                print(json.dumps(diagnostic, separators=(",", ":"), sort_keys=True))
            if proc.returncode != 0:
                rc = _merge_rc(rc, proc.returncode)
            elif diagnostics:
                rc = _merge_rc(rc, 1)
        else:
            proc = subprocess.run(command, cwd=module, check=False)
            rc = _merge_rc(rc, proc.returncode)
    return rc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="checkrun verify",
        description="Run explicit project verification checks.",
    )
    parser.add_argument("--json", action="store_true", help="emit unified JSON diagnostics")
    parser.add_argument(
        "--tool",
        action="append",
        choices=["govulncheck"],
        help="limit verification to one tool; may be repeated",
    )
    parser.add_argument("paths", nargs="*", help="files or directories to verify")
    args = parser.parse_args(argv)

    tools = set(args.tool or ["govulncheck"])
    rc = 0
    if "govulncheck" in tools:
        modules = discover_go_modules(args.paths or _DEFAULT_PATHS)
        rc = _merge_rc(rc, run_govulncheck(modules, json_mode=args.json))
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
