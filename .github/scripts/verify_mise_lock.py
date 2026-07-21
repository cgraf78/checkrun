#!/usr/bin/env python3
"""Verify that Checkrun's CI Mise manifest and lockfile agree."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

import tomllib


def load(path: Path) -> dict[str, Any]:
    """Load a TOML document with an actionable error on failure."""
    try:
        with path.open("rb") as stream:
            return tomllib.load(stream)
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise ValueError(f"cannot read {path}: {error}") from error


def verify(config: dict[str, Any], lock: dict[str, Any]) -> list[str]:
    """Return every manifest/lock consistency error."""
    configured = set(config.get("tools", {}))
    locked = set(lock.get("tools", {}))
    errors = [f"missing lock entry: {name}" for name in sorted(configured - locked)]
    errors.extend(f"stale lock entry: {name}" for name in sorted(locked - configured))

    platforms = set(config.get("settings", {}).get("lockfile_platforms", []))
    if not platforms:
        errors.append("settings.lockfile_platforms must not be empty")

    for name in sorted(configured & locked):
        entries = lock["tools"][name]
        if not isinstance(entries, list) or len(entries) != 1:
            errors.append(f"{name}: expected exactly one locked version")
            continue

        entry = entries[0]
        if entry.get("backend") != name:
            errors.append(f"{name}: backend does not match the manifest key")
        if not entry.get("version"):
            errors.append(f"{name}: locked version is empty")

        locked_platforms = {
            key.removeprefix("platforms.") for key in entry if key.startswith("platforms.")
        }
        for platform in sorted(platforms - locked_platforms):
            errors.append(f"{name}: missing platform {platform}")
        for platform in sorted(locked_platforms - platforms):
            errors.append(f"{name}: stale platform {platform}")
        for platform in sorted(platforms & locked_platforms):
            asset = entry[f"platforms.{platform}"]
            if not asset.get("url"):
                errors.append(f"{name}: {platform} has no locked URL")

    return errors


def main() -> int:
    """Validate the configured manifest and lockfile paths."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("lock", type=Path)
    args = parser.parse_args()

    try:
        errors = verify(load(args.config), load(args.lock))
    except ValueError as error:
        print(f"mise lock verification failed: {error}", file=sys.stderr)
        return 1

    if errors:
        for error in errors:
            print(f"mise lock verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
