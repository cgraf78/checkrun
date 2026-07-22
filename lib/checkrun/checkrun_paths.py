#!/usr/bin/env python3
"""Own Checkrun's user configuration and data directory policy."""

from __future__ import annotations

import os
from pathlib import Path

__all__ = ["config_dir", "data_dir"]


def _xdg_root(variable: str, fallback: Path) -> Path:
    """Return an absolute XDG root or its HOME-derived fallback."""

    value = os.environ.get(variable)
    if value:
        path = Path(value)
        if path.is_absolute():
            return path
    return fallback


def config_dir() -> Path:
    """Return the active Checkrun configuration directory."""

    override = os.environ.get("CHECKRUN_CONFIG_DIR")
    if override:
        value = os.path.expandvars(os.path.expanduser(override))
        path = Path(value)
        if not path.is_absolute():
            path = Path.cwd() / path
        return path.resolve(strict=False)
    return _xdg_root("XDG_CONFIG_HOME", Path.home() / ".config") / "checkrun"


def data_dir() -> Path:
    """Return the XDG data root used for Checkrun-owned payloads."""

    return _xdg_root("XDG_DATA_HOME", Path.home() / ".local/share")
