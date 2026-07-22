#!/usr/bin/env python3
"""Own Checkrun's user configuration and data directory policy."""

from __future__ import annotations

import argparse
import os
from pathlib import Path

__all__ = ["config_dir", "data_dir"]


def _xdg_root(variable: str, fallback: str) -> Path:
    """Return an absolute XDG root or its HOME-derived fallback."""

    value = os.environ.get(variable)
    if value:
        path = Path(value)
        if path.is_absolute():
            return path
    # Keep HOME discovery lazy. An absolute XDG root is a complete path and
    # must remain usable in service or test environments without HOME.
    return Path.home() / fallback


def config_dir() -> Path:
    """Return the active Checkrun configuration directory."""

    override = os.environ.get("CHECKRUN_CONFIG_DIR")
    if override:
        value = os.path.expandvars(os.path.expanduser(override))
        path = Path(value)
        if not path.is_absolute():
            path = Path.cwd() / path
        return path.resolve(strict=False)
    return _xdg_root("XDG_CONFIG_HOME", ".config") / "checkrun"


def data_dir() -> Path:
    """Return the XDG data root used for Checkrun-owned payloads."""

    return _xdg_root("XDG_DATA_HOME", ".local/share")


def main() -> int:
    """Print a path resolved through Checkrun's shared path policy."""

    parser = argparse.ArgumentParser()
    parser.add_argument("path", choices=("config",))
    args = parser.parse_args()

    if args.path == "config":
        print(config_dir())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
