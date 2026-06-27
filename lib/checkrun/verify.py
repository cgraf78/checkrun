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
import re
import shutil
import subprocess
from collections.abc import Callable
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
    "target",
    "vendor",
}


def _abs(path: str) -> Path:
    return Path(path).expanduser().resolve(strict=False)


def _nearest_project_root(start: Path, required_files: tuple[str, ...]) -> Path | None:
    current = start if start.is_dir() else start.parent
    previous: Path | None = None
    while current != previous:
        if all((current / name).is_file() for name in required_files):
            return current.resolve(strict=False)
        if current.parent == current:
            break
        previous = current
        current = current.parent
    return None


def _walk_project_roots(root: Path, required_files: tuple[str, ...]) -> list[Path]:
    roots: list[Path] = []
    if not root.is_dir():
        return roots

    # Directory arguments should mean "verify projects under here", while file
    # arguments mean "verify the nearest owning project". `os.walk` lets us skip
    # dependency/cache trees without depending on `fd` or GNU find at runtime.
    for dir_path, dir_names, file_names in os.walk(root):
        dir_names[:] = [name for name in dir_names if name not in _SKIP_WALK_DIRS]
        if all(name in file_names for name in required_files):
            roots.append(Path(dir_path).resolve(strict=False))
    return roots


def _nearest_go_module(start: Path) -> Path | None:
    return _nearest_project_root(start, ("go.mod",))


def _walk_go_modules(root: Path) -> list[Path]:
    return _walk_project_roots(root, ("go.mod",))


def _nearest_cargo_audit_project(start: Path) -> Path | None:
    return _nearest_project_root(start, ("Cargo.toml", "Cargo.lock"))


def _walk_cargo_audit_projects(root: Path) -> list[Path]:
    return _walk_project_roots(root, ("Cargo.toml", "Cargo.lock"))


def _go_module_path(module: Path) -> str | None:
    try:
        content = (module / "go.mod").read_text(encoding="utf-8")
    except OSError:
        return None
    match = re.search(r"(?m)^\s*module\s+([^\s]+)", content)
    if match:
        return match.group(1)
    return None


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


def discover_cargo_audit_projects(paths: list[str]) -> list[Path]:
    projects: list[Path] = []
    seen: set[str] = set()

    for raw_path in paths or _DEFAULT_PATHS:
        path = _abs(raw_path)
        candidates: list[Path] = []
        if path.is_dir():
            candidates = _walk_cargo_audit_projects(path)
            if not candidates:
                nearest = _nearest_cargo_audit_project(path)
                if nearest:
                    candidates = [nearest]
        elif path.is_file():
            nearest = _nearest_cargo_audit_project(path.parent)
            if nearest:
                candidates = [nearest]

        for project in candidates:
            key = str(project)
            if key not in seen:
                seen.add(key)
                projects.append(project)

    return projects


def _position_from_trace(
    module: Path,
    module_path: str | None,
    finding: dict[str, Any],
) -> tuple[str, int, int]:
    for frame in finding.get("trace", []) or []:
        if not isinstance(frame, dict):
            continue
        # govulncheck trace positions are relative to the enclosing frame's
        # module, and traces start at the vulnerable dependency before walking
        # back to the user's entry point. Only resolve positions from the module
        # we scanned; dependency positions would otherwise become fake paths
        # under this repository.
        frame_module = frame.get("module")
        if (
            module_path
            and isinstance(frame_module, str)
            and frame_module
            and frame_module != module_path
        ):
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


def _json_error(path: Path, source: str, message: str) -> dict[str, Any]:
    return {
        "path": str(path.resolve(strict=False)),
        "line": 1,
        "col": 1,
        "severity": "error",
        "code": None,
        "message": message,
        "source": source,
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
    module_path = _go_module_path(module)
    for finding in findings:
        path, line_no, col = _position_from_trace(module, module_path, finding)
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


def _cargo_audit_message(vulnerability: dict[str, Any]) -> str:
    advisory = vulnerability.get("advisory")
    if not isinstance(advisory, dict):
        advisory = {}
    package = vulnerability.get("package")
    if not isinstance(package, dict):
        package = {}
    versions = vulnerability.get("versions")
    if not isinstance(versions, dict):
        versions = {}

    vuln_id = str(advisory.get("id") or vulnerability.get("ID") or "cargo-audit")
    title = advisory.get("title") or vulnerability.get("Title")
    name = package.get("name") or advisory.get("package") or vulnerability.get("Crate")
    version = package.get("version") or vulnerability.get("Version")
    parts: list[str] = []
    if isinstance(title, str) and title:
        parts.append(title)
    if isinstance(name, str) and name:
        package_text = name
        if isinstance(version, str) and version:
            package_text += f" {version}"
        parts.append(package_text)
    patched = versions.get("patched")
    if isinstance(patched, list):
        patched_versions = [str(item) for item in patched if str(item)]
        if patched_versions:
            parts.append("patched in " + ", ".join(patched_versions))
    if parts:
        return f"{vuln_id}: " + "; ".join(parts)
    return vuln_id


def _parse_cargo_audit_json(project: Path, stdout: str) -> list[dict[str, Any]]:
    if not stdout.strip():
        return []
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError:
        return []
    if not isinstance(payload, dict):
        return []

    # cargo-audit has kept the useful report data structured, but older examples
    # and downstream wrappers differ on whether `vulnerabilities` is the list
    # itself or an object containing `list`. Accept both so Checkrun's contract
    # is tied to vulnerability records, not one cargo-audit release's wrapper.
    vulnerabilities = payload.get("vulnerabilities")
    if isinstance(vulnerabilities, dict):
        vuln_list = vulnerabilities.get("list")
    else:
        vuln_list = vulnerabilities
    if not isinstance(vuln_list, list):
        return []

    diagnostics: list[dict[str, Any]] = []
    lockfile = project / "Cargo.lock"
    for vulnerability in vuln_list:
        if not isinstance(vulnerability, dict):
            continue
        advisory = vulnerability.get("advisory")
        if not isinstance(advisory, dict):
            advisory = {}
        code = advisory.get("id") or vulnerability.get("ID")
        diagnostics.append(
            {
                "path": str(lockfile.resolve(strict=False)),
                "line": 1,
                "col": 1,
                "severity": "error",
                "code": str(code) if isinstance(code, str) and code else "cargo-audit",
                "message": _cargo_audit_message(vulnerability),
                "source": "cargo-audit",
            }
        )
    return diagnostics


def _merge_rc(current: int, incoming: int) -> int:
    if incoming == 0:
        return current
    if current == 0:
        return incoming
    return current


def _run_project_tool(
    projects: list[Path],
    *,
    human_command: list[str],
    json_command: list[str],
    parse_json: Callable[[Path, str], list[dict[str, Any]]],
    error_path: Callable[[Path], Path],
    source: str,
    json_mode: bool,
) -> int:
    """Run a project-scoped verifier and normalize its JSON diagnostics."""
    rc = 0
    for project in projects:
        if json_mode:
            proc = subprocess.run(
                json_command,
                cwd=project,
                text=True,
                capture_output=True,
                check=False,
            )
            diagnostics = parse_json(project, proc.stdout)
            if proc.returncode != 0 and not diagnostics and proc.stderr.strip():
                # govulncheck's JSON stream is structured when scanning reaches
                # findings; cargo-audit behaves similarly for normal advisory
                # reports. Transport/setup failures can still arrive only on
                # stderr, so expose one synthetic diagnostic rather than an
                # empty non-zero JSON run.
                diagnostics = [
                    _json_error(
                        error_path(project),
                        source,
                        proc.stderr.strip().splitlines()[-1],
                    )
                ]
            for diagnostic in diagnostics:
                print(json.dumps(diagnostic, separators=(",", ":"), sort_keys=True))
            if proc.returncode != 0:
                rc = _merge_rc(rc, proc.returncode)
            elif diagnostics:
                rc = _merge_rc(rc, 1)
        else:
            proc = subprocess.run(human_command, cwd=project, check=False)
            rc = _merge_rc(rc, proc.returncode)
    return rc


def run_govulncheck(modules: list[Path], *, json_mode: bool) -> int:
    if shutil.which("govulncheck") is None:
        return 0

    return _run_project_tool(
        modules,
        human_command=["govulncheck", "./..."],
        json_command=["govulncheck", "-json", "./..."],
        parse_json=_parse_govulncheck_json,
        error_path=lambda module: module / "go.mod",
        source="govulncheck",
        json_mode=json_mode,
    )


def run_cargo_audit(projects: list[Path], *, json_mode: bool) -> int:
    # Cargo discovers external subcommands through `cargo-*` binaries, but the
    # stable user/tool interface is `cargo audit`. Check both names so missing
    # cargo-audit remains a quiet optional-backend skip instead of a Cargo error.
    if shutil.which("cargo") is None or shutil.which("cargo-audit") is None:
        return 0

    return _run_project_tool(
        projects,
        human_command=["cargo", "audit"],
        json_command=["cargo", "audit", "--json"],
        parse_json=_parse_cargo_audit_json,
        error_path=lambda project: project / "Cargo.lock",
        source="cargo-audit",
        json_mode=json_mode,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="checkrun verify",
        description="Run explicit project verification checks.",
    )
    parser.add_argument("--json", action="store_true", help="emit unified JSON diagnostics")
    parser.add_argument(
        "--tool",
        action="append",
        choices=["cargo-audit", "govulncheck"],
        help="limit verification to one tool; may be repeated",
    )
    parser.add_argument("paths", nargs="*", help="files or directories to verify")
    args = parser.parse_args(argv)

    tools = set(args.tool or ["cargo-audit", "govulncheck"])
    rc = 0
    if "cargo-audit" in tools:
        projects = discover_cargo_audit_projects(args.paths or _DEFAULT_PATHS)
        rc = _merge_rc(rc, run_cargo_audit(projects, json_mode=args.json))
    if "govulncheck" in tools:
        modules = discover_go_modules(args.paths or _DEFAULT_PATHS)
        rc = _merge_rc(rc, run_govulncheck(modules, json_mode=args.json))
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
