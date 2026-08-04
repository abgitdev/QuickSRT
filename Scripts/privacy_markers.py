#!/usr/bin/env python3
"""Shared byte-level privacy markers without embedding a marker in this file."""

from __future__ import annotations

from pathlib import Path


_SLASH = bytes((0x2F,))
PRIVATE_PATH_MARKERS = (
    _SLASH + b"Users" + _SLASH,
    _SLASH + b"home" + _SLASH,
    _SLASH + b"private" + _SLASH + b"var" + _SLASH + b"folders" + _SLASH,
)


def contains_private_marker(path: Path, marker: bytes) -> bool:
    overlap = max(0, len(marker) - 1)
    tail = b""
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            data = tail + chunk
            if marker in data:
                return True
            tail = data[-overlap:] if overlap else b""
    return False
