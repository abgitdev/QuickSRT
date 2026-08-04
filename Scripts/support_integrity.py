#!/usr/bin/env python3
"""Create and verify complete SHA-256 manifests and scan support bundles."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
from pathlib import Path, PurePosixPath

from privacy_markers import PRIVATE_PATH_MARKERS, contains_private_marker

MANIFEST_NAME = "support-manifest.json"
FORBIDDEN_NAMES = (
    "PROJECT_MEMORY",
    "_PROJECT_AUDIT",
    "_PROJECT_RESEARCH",
    "_PRIVATE_CHATS",
)
IGNORED_GENERATED_PARTS = {"__pycache__"}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def safe_relative(root: Path, path: Path) -> str:
    relative = path.relative_to(root).as_posix()
    pure = PurePosixPath(relative)
    if pure.is_absolute() or ".." in pure.parts:
        raise ValueError(f"unsafe manifest path: {relative}")
    return relative


def inventory(root: Path, manifest_name: str = MANIFEST_NAME) -> list[dict[str, object]]:
    entries: list[dict[str, object]] = []
    for path in sorted(root.rglob("*")):
        relative = safe_relative(root, path)
        if relative == manifest_name:
            continue
        if path.is_symlink():
            target = os.readlink(path)
            if os.path.isabs(target):
                raise ValueError(f"absolute symlink is not allowed: {relative} -> {target}")
            resolved = (path.parent / target).resolve()
            try:
                resolved.relative_to(root.resolve())
            except ValueError as error:
                raise ValueError(f"escaping symlink: {relative} -> {target}") from error
            entries.append({"path": relative, "type": "symlink", "target": target})
        elif path.is_file():
            mode = stat.S_IMODE(path.stat().st_mode)
            entries.append(
                {
                    "path": relative,
                    "type": "file",
                    "size": path.stat().st_size,
                    "sha256": digest(path),
                    "executable": bool(mode & 0o111),
                }
            )
    return entries


def create_manifest(root: Path, output: Path) -> None:
    payload = {
        "schema_version": 1,
        "hash": "sha256",
        "entries": inventory(root, output.name),
    }
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def verify_manifest(root: Path, manifest_path: Path) -> None:
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected = payload.get("entries")
    if payload.get("schema_version") != 1 or not isinstance(expected, list):
        raise ValueError("unsupported or malformed support manifest")
    actual = inventory(root, manifest_path.name)
    if actual != expected:
        expected_by_path = {entry["path"]: entry for entry in expected}
        actual_by_path = {entry["path"]: entry for entry in actual}
        paths = sorted(set(expected_by_path) | set(actual_by_path))
        changed = [path for path in paths if expected_by_path.get(path) != actual_by_path.get(path)]
        summary = ", ".join(changed[:10])
        raise ValueError(f"support manifest mismatch: {summary}")


def privacy_scan(roots: list[Path]) -> None:
    failures: list[str] = []
    for root in roots:
        if not root.exists():
            continue
        paths = [root] if root.is_file() else root.rglob("*")
        for path in paths:
            if any(part in IGNORED_GENERATED_PARTS for part in path.parts):
                continue
            relative = str(path)
            if any(name in path.name for name in FORBIDDEN_NAMES):
                failures.append(f"forbidden local artifact: {relative}")
            if path.is_file() and not path.is_symlink():
                for marker in PRIVATE_PATH_MARKERS:
                    if contains_private_marker(path, marker):
                        failures.append(f"private path marker {marker.decode()!r}: {relative}")
                        break
    if failures:
        raise ValueError("privacy scan failed:\n" + "\n".join(failures[:50]))


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    create = subparsers.add_parser("create")
    create.add_argument("--root", type=Path, required=True)
    create.add_argument("--output", type=Path)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--root", type=Path, required=True)
    verify.add_argument("--manifest", type=Path)
    scan = subparsers.add_parser("scan")
    scan.add_argument("--root", type=Path, action="append", required=True)
    args = parser.parse_args()
    try:
        if args.command == "create":
            output = args.output or args.root / MANIFEST_NAME
            create_manifest(args.root.resolve(), output.resolve())
        elif args.command == "verify":
            manifest = args.manifest or args.root / MANIFEST_NAME
            verify_manifest(args.root.resolve(), manifest.resolve())
        else:
            privacy_scan([root.resolve() for root in args.root])
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
