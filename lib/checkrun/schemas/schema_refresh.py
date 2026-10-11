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


def _mentions_ref(document: Any) -> bool:
    """Return whether `document` contains any `$ref` key at all.

    A cheap pre-check, so payloads without references never need the optional
    `referencing` library and refresh keeps working on lean hosts for them.
    """

    stack = [document]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            if "$ref" in node:
                return True
            stack.extend(node.values())
        elif isinstance(node, list):
            stack.extend(node)
    return False


def _referencing() -> Any:
    """Import the `referencing` pieces vendoring needs, or explain what is missing."""

    try:
        import jsonschema_specifications
        import referencing.jsonschema
    except ModuleNotFoundError as exc:
        raise RefreshError(
            "vendoring schema references needs the `referencing` library "
            "(install jsonschema 4.18 or newer)"
        ) from exc
    return referencing.jsonschema, jsonschema_specifications.REGISTRY


def _specification(contents: Any, default: Any) -> Any:
    """Return the JSON Schema dialect `contents` declares, else `default`."""

    referencing_jsonschema, _meta = _referencing()
    dialect = contents.get("$schema") if isinstance(contents, dict) else None
    if not isinstance(dialect, str):
        return default
    return referencing_jsonschema.specification_with(dialect, default=default)


def _schema_walk(document: Any, url: str) -> list[tuple[dict[str, Any], str]]:
    """Return every subschema of `document` with its resolution base URI.

    The walk uses the `referencing` library that validation itself resolves
    references with, so refresh agrees with validation about which keyword is
    the dialect's id (`id` before draft 6, `$id` after), which values are
    subschemas (never `examples`, `enum`, `default`, or `const` data), and how
    a nested id changes the base. An implementation of our own would drift.
    """

    referencing_jsonschema, _meta = _referencing()
    walked: list[tuple[dict[str, Any], str]] = []
    stack: list[tuple[Any, Any, str]] = [
        (document, _specification(document, referencing_jsonschema.DRAFT7), url)
    ]
    while stack:
        contents, spec, base = stack.pop()
        if not isinstance(contents, dict):
            continue
        own_id = spec.id_of(contents)
        if isinstance(own_id, str) and own_id:
            base = urllib.parse.urljoin(base, own_id)
        walked.append((contents, base))
        for subschema in spec.subresources_of(contents):
            stack.append((subschema, _specification(subschema, spec), base))
    return walked


def _remote_refs(document: Any, url: str) -> list[str]:
    """Return the external documents `document` references, without fragments.

    References to the document's own URL or any id inside it resolve within
    the document (SchemaStore's root `$id` even differs from its fetch URL),
    and JSON Schema meta-schemas ship with the validator, so neither is
    fetched.
    """

    _referencing_jsonschema, meta_schemas = _referencing()
    walked = _schema_walk(document, url)
    own = {urllib.parse.urldefrag(url).url} | {
        urllib.parse.urldefrag(base).url for _contents, base in walked
    }
    found: list[str] = []
    for contents, base in walked:
        ref = contents.get("$ref")
        if not isinstance(ref, str) or ref.startswith("#"):
            continue
        target = urllib.parse.urldefrag(urllib.parse.urljoin(base, ref)).url
        if not target or target in own or target in found:
            continue
        try:
            meta_schemas.contents(target)
        except LookupError:
            found.append(target)
    return found


def _with_base_id(schema: Any, source: str) -> Any:
    """Record the fetch URL as the base URI of a payload that has references.

    JSON Schema resolves relative references against the retrieval URI when a
    document declares no id. A pinned payload is read from disk, where that URI
    is lost, so without this a relative `$ref` would be vendored under the
    source URL by refresh but looked up without a base by validation. Payloads
    that already declare an id, or reference nothing external, are untouched.
    """

    if not isinstance(schema, dict) or not _mentions_ref(schema):
        return schema
    if not _remote_refs(schema, source):
        return schema
    referencing_jsonschema, _meta = _referencing()
    spec = _specification(schema, referencing_jsonschema.DRAFT7)
    if spec.id_of(schema):
        return schema
    keyword = "id" if spec.name in {"draft-03", "draft-04"} else "$id"
    # Keep `$schema` first, as upstream documents conventionally do.
    ordered: dict[str, Any] = {"$schema": schema["$schema"]} if "$schema" in schema else {}
    ordered[keyword] = source
    ordered.update(schema)
    return ordered


def _check_ref_scheme(document_url: str, target: str) -> None:
    """Reject a reference that may not be fetched from where it appears.

    Fetched documents are untrusted input. A remote payload containing
    `"$ref": "file:///home/user/.ssh/id_ed25519"` must not make refresh read a
    local file and vendor it into a directory a bot commits, and an https
    payload must not pull its references over plain http. A reference must
    therefore use its document's own scheme, and only https or file (the
    latter for hermetic tests and local staging).
    """

    document_scheme = urllib.parse.urlsplit(document_url).scheme
    target_scheme = urllib.parse.urlsplit(target).scheme
    if target_scheme != document_scheme or target_scheme not in {"https", "file"}:
        raise RefreshError(
            f"refusing $ref {target} from {document_url}: a reference must use its "
            "document's scheme, https or file"
        )


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
    if not _mentions_ref(schema):
        return results
    queue: list[tuple[Any, str]] = [(schema, candidate.source)]
    while queue:
        document, url = queue.pop(0)
        for target in _remote_refs(document, url):
            _check_ref_scheme(url, target)
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
        schema = _with_base_id(schema, candidate.source)
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
