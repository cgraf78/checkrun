#!/usr/bin/env python3
"""Refresh pinned public schema payloads from Checkrun association policy.

Normal Checkrun validation is intentionally offline: schema-lint reads local
payloads through schema_policy.schema_path(). This command is the explicit
maintenance path that updates those pinned payloads from their public `source`
URLs, along with every document they reference remotely, and lets CI report
drift without making every lint run depend on the network.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from json import JSONDecodeError
from pathlib import Path
from typing import Any

import schema_policy

USER_AGENT = "checkrun-schema-refresh/1"
DEFAULT_TIMEOUT_SECONDS = 20.0


class RefreshError(Exception):
    """Expected refresh failure for one association."""


@dataclass(frozen=True)
class Candidate:
    """A refreshable association and its resolved input/output locations."""

    name: str
    source: str
    destination: Path


@dataclass(frozen=True)
class Result:
    """Refresh outcome for one association."""

    status: str
    name: str
    destination: Path | None = None
    source: str | None = None
    message: str = ""


def _association_name(association: dict[str, Any]) -> str:
    name = association.get("name")
    return name if isinstance(name, str) and name else "<unnamed>"


def _source(association: dict[str, Any]) -> str | None:
    source = association.get("source")
    return source if isinstance(source, str) and source else None


def _is_dependency_owned(association: dict[str, Any]) -> bool:
    dependency = association.get("dependency")
    return isinstance(dependency, str) and bool(dependency)


def _refresh_candidates(
    policy: dict[str, Any],
    *,
    association_filter: str | None = None,
) -> list[Candidate]:
    """Return web-backed associations whose local payload is dotfile-pinned.

    A `dependency` schema is public API owned by that dependency repo. Refreshing
    it here would duplicate dependency release/update policy in Checkrun, so
    those entries are deliberately skipped even if they also declare a source
    for editor integrations.
    """

    associations = policy.get("associations", [])
    if not isinstance(associations, list):
        raise RefreshError("schema policy associations must be a list")

    candidates: list[Candidate] = []
    for item in associations:
        if not isinstance(item, dict):
            continue
        name = _association_name(item)
        if association_filter and name != association_filter:
            continue
        if _is_dependency_owned(item):
            continue
        source = _source(item)
        if not source:
            continue
        destination = schema_policy.schema_path(policy, item)
        candidates.append(
            Candidate(
                name=name,
                source=source,
                destination=destination,
            )
        )
    return candidates


def _read_url(url: str, *, timeout: float) -> bytes:
    """Read a refresh source.

    `file://` support exists primarily for hermetic tests and local staging.
    Production policies normally use HTTPS, but keeping file sources here makes
    the command testable without a local web server and without teaching tests
    to mock urllib internals.
    """

    parsed = urllib.parse.urlparse(url)
    if parsed.scheme == "file":
        try:
            return Path(urllib.request.url2pathname(parsed.path)).read_bytes()
        except OSError as exc:
            raise RefreshError(f"read failed: {exc}") from exc

    if parsed.scheme not in {"http", "https"}:
        raise RefreshError(f"unsupported source scheme: {parsed.scheme or '<none>'}")

    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        raise RefreshError(f"HTTP {exc.code}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RefreshError(f"fetch failed: {exc}") from exc


def _decode_schema(payload: bytes) -> Any:
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RefreshError(f"schema is not UTF-8: {exc}") from exc
    try:
        return json.loads(text)
    except JSONDecodeError as exc:
        raise RefreshError(f"schema is not valid JSON: {exc}") from exc


def _check_schema(schema: Any) -> None:
    """Validate the fetched payload as a JSON Schema when jsonschema exists.

    jsonschema is already an optional schema-lint dependency. Refresh is a
    maintenance command, so when the library is installed we should reject
    invalid upstream payloads before they overwrite the pinned copy. On lean
    hosts the JSON parse check still protects against corrupt downloads; CI and
    developer machines that run the full test suite exercise the stronger path.
    """

    try:
        import jsonschema  # type: ignore[import-not-found]
    except ModuleNotFoundError:
        return

    try:
        validator_cls = jsonschema.validators.validator_for(schema)
        validator_cls.check_schema(schema)
    except jsonschema.exceptions.SchemaError as exc:
        raise RefreshError(f"invalid JSON Schema: {exc.message}") from exc


def _encoded(schema: Any) -> bytes:
    # Write a canonical generated form so future refresh diffs are semantic and
    # not a mix of upstream minified/prettified styles. Preserve object order
    # from upstream because schema authors often group related keys deliberately.
    return (json.dumps(schema, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def _read_existing(path: Path) -> bytes | None:
    try:
        return path.read_bytes()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise RefreshError(f"cannot read existing schema: {exc}") from exc


def _write_atomic(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    tmp_path = Path(tmp)
    try:
        with os.fdopen(fd, "wb") as file:
            file.write(content)
            file.flush()
            os.fsync(file.fileno())
        tmp_path.replace(path)
    except OSError as exc:
        try:
            tmp_path.unlink()
        except OSError:
            pass
        raise RefreshError(f"cannot write schema: {exc}") from exc


# A schema graph larger than this is almost certainly a reference loop through
# ever-changing URLs or a misconfigured source, not a real payload; stop rather
# than crawl indefinitely.
MAX_VENDORED_REFS = 200


def _document_ids(document: Any, base: str) -> set[str]:
    """Return the URLs a document answers to: its fetch URL and any `$id`s.

    References to these resolve inside the document itself, so they must not
    be fetched as separate resources (an embedded `$id` usually 404s, and the
    root `$id` often differs from the fetch URL, as SchemaStore's does).
    """

    ids = {urllib.parse.urldefrag(base).url}
    stack: list[tuple[Any, str]] = [(document, base)]
    while stack:
        node, node_base = stack.pop()
        if isinstance(node, dict):
            node_id = node.get("$id")
            if isinstance(node_id, str) and node_id:
                node_base = urllib.parse.urljoin(node_base, node_id)
                ids.add(urllib.parse.urldefrag(node_base).url)
            stack.extend((value, node_base) for value in node.values())
        elif isinstance(node, list):
            stack.extend((value, node_base) for value in node)
    return ids


def _remote_refs(document: Any, base: str) -> list[str]:
    """Return the external documents `document` references, without fragments.

    Relative references resolve against the nearest enclosing `$id`, the same
    rule validators use, so a relative `$ref` in a fetched payload is vendored
    under the absolute URL that validation will later ask for.
    """

    own = _document_ids(document, base)
    found: list[str] = []
    stack: list[tuple[Any, str]] = [(document, base)]
    while stack:
        node, node_base = stack.pop()
        if isinstance(node, dict):
            node_id = node.get("$id")
            if isinstance(node_id, str) and node_id:
                node_base = urllib.parse.urljoin(node_base, node_id)
            ref = node.get("$ref")
            if isinstance(ref, str) and not ref.startswith("#"):
                target = urllib.parse.urldefrag(urllib.parse.urljoin(node_base, ref)).url
                if target and target not in own and target not in found:
                    found.append(target)
            stack.extend((value, node_base) for value in node.values())
        elif isinstance(node, list):
            stack.extend((value, node_base) for value in node)
    return found


def _vendor_refs(
    candidate: Candidate,
    schema: Any,
    *,
    check: bool,
    timeout: float,
    seen: set[Path],
) -> list[Result]:
    """Fetch every document the payload transitively references, beside it.

    `seen` spans the whole run, so a document several payloads share (such as
    SchemaStore's common fragments) is fetched and reported once.
    """

    results: list[Result] = []
    queue: list[tuple[Any, str]] = [(schema, candidate.source)]
    while queue:
        document, url = queue.pop(0)
        for target in _remote_refs(document, url):
            path = schema_policy._vendored_ref_path(candidate.destination, target)
            label = f"{candidate.name} ref"
            if path is None:
                raise RefreshError(f"cannot vendor $ref {target}: unsupported URL")
            if path in seen:
                continue
            seen.add(path)
            if len(seen) > MAX_VENDORED_REFS:
                raise RefreshError(f"more than {MAX_VENDORED_REFS} referenced documents")
            try:
                referenced = _decode_schema(_read_url(target, timeout=timeout))
            except RefreshError as exc:
                raise RefreshError(f"$ref {target}: {exc}") from exc
            content = _encoded(referenced)
            existing = _read_existing(path)
            if existing == content:
                results.append(Result("current", label, path, target))
            elif check:
                message = "would update" if existing is not None else "would create"
                results.append(Result("changed", label, path, target, message))
            else:
                _write_atomic(path, content)
                status = "updated" if existing is not None else "created"
                results.append(Result(status, label, path, target))
            queue.append((referenced, target))
    return results


def _refresh_candidate(
    candidate: Candidate, *, check: bool, timeout: float, seen: set[Path]
) -> list[Result]:
    try:
        payload = _read_url(candidate.source, timeout=timeout)
        schema = _decode_schema(payload)
        _check_schema(schema)
        content = _encoded(schema)
        existing = _read_existing(candidate.destination)
        if existing == content:
            result = Result("current", candidate.name, candidate.destination, candidate.source)
        elif check:
            message = "would update" if existing is not None else "would create"
            result = Result(
                "changed", candidate.name, candidate.destination, candidate.source, message
            )
        else:
            _write_atomic(candidate.destination, content)
            status = "updated" if existing is not None else "created"
            result = Result(status, candidate.name, candidate.destination, candidate.source)
        # References can change upstream while the payload itself does not,
        # so they are refreshed on every run, not only when the payload moves.
        refs = _vendor_refs(candidate, schema, check=check, timeout=timeout, seen=seen)
        return [result, *refs]
    except RefreshError as exc:
        return [Result("failed", candidate.name, candidate.destination, candidate.source, str(exc))]


def _load_policy() -> tuple[Path, dict[str, Any]]:
    path = schema_policy.policy_path()
    try:
        policy = schema_policy.load_policy(path)
    except schema_policy.SchemaPolicyError as exc:
        raise RefreshError(str(exc)) from exc
    if policy is None:
        raise RefreshError(f"schema policy not found: {path}")
    return path, policy


def _print_result(result: Result) -> None:
    destination = f" {result.destination}" if result.destination is not None else ""
    if result.status == "failed":
        print(f"failed  {result.name}{destination}: {result.message}")
    elif result.message:
        print(f"{result.status:<7} {result.name}{destination}: {result.message}")
    else:
        print(f"{result.status:<7} {result.name}{destination}")


def _positive_timeout(value: str) -> float:
    try:
        timeout = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("timeout must be a number") from exc
    if not math.isfinite(timeout):
        # argparse accepts float spellings like "nan" and "inf", but socket
        # timeout handling does not. Reject them here so unattended refresh jobs
        # get a normal usage error instead of a transport-specific traceback.
        raise argparse.ArgumentTypeError("timeout must be finite")
    if timeout <= 0:
        # The timeout is a reliability control, not a scheduling primitive. A
        # zero or negative value makes urllib fail in transport-specific ways,
        # so reject it at the CLI boundary where users get a normal usage error.
        raise argparse.ArgumentTypeError("timeout must be greater than zero")
    return timeout


def run(
    *,
    check: bool = False,
    association_filter: str | None = None,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
) -> int:
    """Refresh configured schema payloads.

    Return codes intentionally mirror CI semantics:
      0 = all selected schemas are current or were updated successfully
      1 = selected schemas differ in --check mode, or at least one refresh failed
      2 = policy/selection problem
    """

    try:
        _policy_path, policy = _load_policy()
    except (RefreshError, schema_policy.PathPolicyError) as exc:
        print(f"schema refresh: {exc}")
        return 2

    try:
        candidates = _refresh_candidates(policy, association_filter=association_filter)
    except (RefreshError, schema_policy.PathPolicyError) as exc:
        print(f"schema refresh: {exc}")
        return 2
    if association_filter and not candidates:
        print(f"schema refresh: no refreshable association named {association_filter!r}")
        return 2
    if not candidates:
        print("schema refresh: no refreshable schemas")
        return 0

    seen: set[Path] = set()
    results = [
        result
        for candidate in candidates
        for result in _refresh_candidate(candidate, check=check, timeout=timeout, seen=seen)
    ]
    for result in results:
        _print_result(result)

    if any(result.status == "failed" for result in results):
        return 1
    if check and any(result.status == "changed" for result in results):
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="report drift without writing schema payloads",
    )
    parser.add_argument(
        "--association",
        metavar="NAME",
        help="refresh only one association by exact policy name",
    )
    parser.add_argument(
        "--timeout",
        type=_positive_timeout,
        default=DEFAULT_TIMEOUT_SECONDS,
        help=f"per-source fetch timeout in seconds (default: {DEFAULT_TIMEOUT_SECONDS:g})",
    )
    args = parser.parse_args(argv)
    return run(check=args.check, association_filter=args.association, timeout=args.timeout)


if __name__ == "__main__":
    raise SystemExit(main())
