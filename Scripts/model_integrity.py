#!/usr/bin/env python3
"""Validate the pinned QuickSRT model without deserializing its weights."""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import pathlib
import re
import stat
import struct
import sys
import zipfile


MANIFEST_NAME = "model-manifest.json"
HASH_CHUNK_SIZE = 8 * 1024 * 1024


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(HASH_CHUNK_SIZE):
            digest.update(chunk)
    return digest.hexdigest()


def load_policy(path: pathlib.Path) -> dict:
    raw = path.read_bytes()
    policy = json.loads(raw)
    if policy.get("schema_version") != 1:
        raise ValueError("unsupported model policy schema")
    if not re.fullmatch(r"[0-9a-f]{40}", str(policy.get("revision", ""))):
        raise ValueError("model policy revision must be an exact commit hash")
    files = policy.get("files")
    if not isinstance(files, dict) or set(files) != {"config.json", "weights.npz"}:
        raise ValueError("model policy must define the exact config and weights files")
    policy["_sha256"] = hashlib.sha256(raw).hexdigest()
    return policy


def require_regular_file(path: pathlib.Path, expected_size: int) -> None:
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise ValueError(f"model entry is not a regular file: {path.name}")
    if info.st_size != expected_size:
        raise ValueError(
            f"model size mismatch for {path.name}: expected {expected_size}, got {info.st_size}"
        )


def validate_config(path: pathlib.Path, expected: dict) -> None:
    with path.open("r", encoding="utf-8") as handle:
        actual = json.load(handle)
    if not isinstance(actual, dict) or actual != expected:
        raise ValueError("model config schema or values do not match the pinned model")
    if any(isinstance(value, bool) for value in actual.values() if isinstance(value, int)):
        raise ValueError("model config contains an invalid boolean dimension")


def parse_npy_header(handle, entry_size: int, name: str) -> None:
    if handle.read(6) != b"\x93NUMPY":
        raise ValueError(f"invalid NPY magic: {name}")
    version = tuple(handle.read(2))
    if version == (1, 0):
        length_bytes = handle.read(2)
        if len(length_bytes) != 2:
            raise ValueError(f"truncated NPY header: {name}")
        header_length = struct.unpack("<H", length_bytes)[0]
        prefix_size = 10
    elif version in {(2, 0), (3, 0)}:
        length_bytes = handle.read(4)
        if len(length_bytes) != 4:
            raise ValueError(f"truncated NPY header: {name}")
        header_length = struct.unpack("<I", length_bytes)[0]
        prefix_size = 12
    else:
        raise ValueError(f"unsupported NPY version in {name}: {version}")
    if header_length <= 0 or header_length > 1024 * 1024:
        raise ValueError(f"unsafe NPY header length in {name}")
    header = handle.read(header_length)
    if len(header) != header_length:
        raise ValueError(f"truncated NPY metadata: {name}")
    metadata = ast.literal_eval(header.decode("latin1").strip())
    if not isinstance(metadata, dict) or set(metadata) != {"descr", "fortran_order", "shape"}:
        raise ValueError(f"invalid NPY metadata fields: {name}")
    descriptor = metadata["descr"]
    shape = metadata["shape"]
    if not isinstance(descriptor, str) or re.search(r"[OUSVMm]", descriptor):
        raise ValueError(f"unsafe or non-numeric NPY dtype in {name}")
    size_match = re.search(r"(\d+)$", descriptor)
    if size_match is None:
        raise ValueError(f"invalid NPY dtype size in {name}")
    if metadata["fortran_order"] not in {True, False}:
        raise ValueError(f"invalid NPY order in {name}")
    if not isinstance(shape, tuple) or any(type(value) is not int or value < 0 for value in shape):
        raise ValueError(f"invalid NPY shape in {name}")
    elements = 1
    for dimension in shape:
        elements *= dimension
        if elements > 2_000_000_000:
            raise ValueError(f"unsafe NPY element count in {name}")
    expected_size = prefix_size + header_length + elements * int(size_match.group(1))
    if expected_size != entry_size:
        raise ValueError(f"NPY payload size does not match its schema: {name}")


def validate_npz(path: pathlib.Path, rule: dict) -> None:
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) != int(rule["entries"]):
            raise ValueError("weights archive entry count mismatch")
        if sum(item.file_size for item in entries) != int(rule["uncompressed_size"]):
            raise ValueError("weights archive uncompressed size mismatch")
        seen: set[str] = set()
        for item in entries:
            pure = pathlib.PurePosixPath(item.filename)
            if (
                item.filename in seen
                or pure.is_absolute()
                or ".." in pure.parts
                or len(pure.parts) != 1
                or not item.filename.endswith(".npy")
                or len(item.filename) > 128
            ):
                raise ValueError(f"unsafe weights archive member: {item.filename}")
            seen.add(item.filename)
            if item.compress_type != zipfile.ZIP_STORED:
                raise ValueError(f"unexpected compression in weights archive: {item.filename}")
            if item.file_size > int(rule["maximum_entry_size"]):
                raise ValueError(f"oversized weights archive member: {item.filename}")
            with archive.open(item, "r") as handle:
                parse_npy_header(handle, item.file_size, item.filename)


def expected_manifest(policy: dict) -> dict:
    return {
        "schema_version": 1,
        "policy_id": policy["policy_id"],
        "policy_sha256": policy["_sha256"],
        "repository_id": policy["repository_id"],
        "revision": policy["revision"],
        "files": {
            name: {
                "sha256": rule["sha256"],
                "size": rule["size"],
            }
            for name, rule in sorted(policy["files"].items())
        },
    }


def write_manifest(model: pathlib.Path, policy: dict) -> None:
    target = model / MANIFEST_NAME
    temporary = model / f".{MANIFEST_NAME}.tmp"
    content = json.dumps(expected_manifest(policy), indent=2, sort_keys=True) + "\n"
    with temporary.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, target)


def validate_model(model: pathlib.Path, policy: dict, require_manifest: bool) -> None:
    model = model.resolve(strict=True)
    if not model.is_dir():
        raise ValueError("model path is not a directory")
    allowed = set(policy["files"]) | ({MANIFEST_NAME} if require_manifest else set())
    actual = {entry.name for entry in model.iterdir()}
    if actual != allowed:
        raise ValueError(f"model directory has unexpected or missing entries: {sorted(actual ^ allowed)}")

    for name, rule in policy["files"].items():
        path = model / name
        require_regular_file(path, int(rule["size"]))
        actual_hash = sha256_file(path)
        if actual_hash != rule["sha256"]:
            raise ValueError(f"model SHA-256 mismatch for {name}")

    validate_config(model / "config.json", policy["config"])
    validate_npz(model / "weights.npz", policy["files"]["weights.npz"])

    if require_manifest:
        manifest_path = model / MANIFEST_NAME
        require_regular_file(manifest_path, manifest_path.stat().st_size)
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if manifest != expected_manifest(policy):
            raise ValueError("model manifest is not the trusted manifest for this revision")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, type=pathlib.Path)
    parser.add_argument("--policy", required=True, type=pathlib.Path)
    parser.add_argument("--write-manifest", action="store_true")
    parser.add_argument("--require-manifest", action="store_true")
    args = parser.parse_args()
    try:
        policy = load_policy(args.policy)
        validate_model(args.model, policy, require_manifest=args.require_manifest)
        if args.write_manifest:
            if args.require_manifest:
                raise ValueError("--write-manifest and --require-manifest are mutually exclusive")
            write_manifest(args.model.resolve(strict=True), policy)
            validate_model(args.model, policy, require_manifest=True)
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError, zipfile.BadZipFile) as error:
        print(f"Model integrity error: {error}", file=sys.stderr)
        return 1
    print("Model integrity: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
