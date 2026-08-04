#!/usr/bin/env python3
"""Verify QuickSRT's pinned FFmpeg executables before they can be used."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(*arguments: str) -> str:
    result = subprocess.run(
        arguments,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return result.stdout.strip()


def verify(tools: Path, manifest_path: Path) -> None:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected_arch = manifest["architecture"]
    expected_version = manifest["display_version"]
    required_ffmpeg_filters = set(manifest.get("required_ffmpeg_filters", []))

    for name, metadata in manifest["binaries"].items():
        executable = tools / name
        if not executable.is_file():
            raise RuntimeError(f"missing executable: {executable}")
        if not executable.stat().st_mode & 0o111:
            raise RuntimeError(f"not executable: {executable}")

        actual_hash = sha256(executable)
        if actual_hash != metadata["sha256"]:
            raise RuntimeError(
                f"{name} SHA-256 mismatch: expected {metadata['sha256']}, got {actual_hash}"
            )

        architectures = run("/usr/bin/lipo", "-archs", str(executable)).split()
        if expected_arch not in architectures:
            raise RuntimeError(
                f"{name} does not contain {expected_arch}: {', '.join(architectures)}"
            )
        if "x86_64" in architectures and expected_arch == "arm64":
            raise RuntimeError(f"{name} unexpectedly contains x86_64")

        first_line = run(str(executable), "-version").splitlines()[0]
        if not first_line.startswith(f"{name} version {expected_version}"):
            raise RuntimeError(
                f"{name} version mismatch: expected {expected_version!r}, got {first_line!r}"
            )

        if name == "ffmpeg" and required_ffmpeg_filters:
            available_filters = {
                fields[1]
                for line in run(str(executable), "-filters").splitlines()
                if len(fields := line.split()) >= 3
                and fields[0]
                and all(character in ".TSCAVN" for character in fields[0])
            }
            missing_filters = required_ffmpeg_filters - available_filters
            if missing_filters:
                missing = ", ".join(sorted(missing_filters))
                raise RuntimeError(f"ffmpeg is missing required filters: {missing}")

        run("/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(executable))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tools", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    try:
        verify(args.tools.resolve(), args.manifest.resolve())
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError, RuntimeError) as error:
        print(f"FFmpeg verification failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified pinned FFmpeg tools in {args.tools.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
