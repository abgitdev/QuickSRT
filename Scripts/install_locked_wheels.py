#!/usr/bin/env python3
"""Install an already resolved, hash-locked wheelhouse without executing code."""

from __future__ import annotations

import argparse
import configparser
import csv
import hashlib
import io
import os
import pathlib
import re
import shutil
import stat
import zipfile

from write_runtime_lock import canonical_name, wheel_identity


def expected_lock(path: pathlib.Path) -> dict[tuple[str, str], set[str]]:
    result: dict[tuple[str, str], set[str]] = {}
    current = None
    for line in path.read_text(encoding="utf-8").splitlines():
        requirement = re.match(r"^([A-Za-z0-9_.-]+)==([^\s\\]+)", line)
        if requirement:
            current = (canonical_name(requirement.group(1)), requirement.group(2))
            result.setdefault(current, set())
        digest = re.search(r"--hash=sha256:([0-9a-f]{64})", line)
        if digest and current:
            result[current].add(digest.group(1))
    if not result or any(not hashes for hashes in result.values()):
        raise ValueError("lock is empty or contains an unhashed requirement")
    return result


def safe_member(name: str) -> pathlib.PurePosixPath:
    path = pathlib.PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise ValueError(f"unsafe wheel member: {name}")
    return path


def destination_for(member: pathlib.PurePosixPath, target: pathlib.Path) -> pathlib.Path | None:
    parts = list(member.parts)
    if len(parts) >= 2 and parts[0].endswith(".data"):
        scheme = parts[1]
        remainder = parts[2:]
        if not remainder:
            return None
        if scheme in {"purelib", "platlib"}:
            return target.joinpath(*remainder)
        if scheme == "scripts":
            return target.joinpath("bin", *remainder)
        if scheme in {"data", "headers"}:
            return target.joinpath("wheel-data", scheme, *remainder)
        raise ValueError(f"unsupported wheel data scheme: {scheme}")
    return target.joinpath(*parts)


def extract_wheel(wheel: pathlib.Path, target: pathlib.Path) -> None:
    with zipfile.ZipFile(wheel) as archive:
        for item in archive.infolist():
            member = safe_member(item.filename)
            destination = destination_for(member, target)
            if destination is None:
                continue
            mode = item.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise ValueError(f"wheel contains a symbolic link: {item.filename}")
            if item.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(item) as source, destination.open("wb") as output:
                shutil.copyfileobj(source, output)
            destination.chmod(0o755 if mode & 0o111 else 0o644)


def console_entries(target: pathlib.Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for entry_points in target.glob("*.dist-info/entry_points.txt"):
        parser = configparser.ConfigParser(interpolation=None)
        parser.read(entry_points, encoding="utf-8")
        if parser.has_section("console_scripts"):
            for name, value in parser.items("console_scripts"):
                if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
                    raise ValueError(f"unsafe console script name: {name}")
                result[name] = value.strip()
    return result


def write_console_scripts(target: pathlib.Path) -> None:
    bin_dir = target / "bin"
    bin_dir.mkdir(exist_ok=True)
    for name, entry in sorted(console_entries(target).items()):
        reference = entry.split("[", 1)[0].strip()
        if ":" not in reference:
            raise ValueError(f"unsupported console entry point: {name}={entry}")
        module, attribute = (part.strip() for part in reference.split(":", 1))
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", module + "." + attribute):
            raise ValueError(f"unsafe console entry point: {name}={entry}")
        script = bin_dir / name
        script.write_text(
            "#!/untrusted-build-python\n"
            "import sys\n"
            f"from {module} import {attribute} as entry_point\n"
            "if __name__ == '__main__':\n"
            "    sys.exit(entry_point())\n",
            encoding="utf-8",
        )
        script.chmod(0o755)


def install(lock: pathlib.Path, wheelhouse: pathlib.Path, target: pathlib.Path) -> None:
    expected = expected_lock(lock)
    wheels: dict[tuple[str, str], pathlib.Path] = {}
    for wheel in sorted(wheelhouse.glob("*.whl")):
        identity = wheel_identity(wheel)
        digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
        if digest not in expected.get(identity, set()):
            continue
        if identity in wheels:
            raise ValueError(f"multiple wheels selected for {identity}")
        wheels[identity] = wheel
    missing = sorted(set(expected) - set(wheels))
    if missing:
        raise ValueError(f"locked wheels are missing: {missing}")
    target.mkdir(parents=True, exist_ok=True)
    for identity in sorted(wheels):
        extract_wheel(wheels[identity], target)
    write_console_scripts(target)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", required=True, type=pathlib.Path)
    parser.add_argument("--wheelhouse", required=True, type=pathlib.Path)
    parser.add_argument("--target", required=True, type=pathlib.Path)
    args = parser.parse_args()
    install(args.lock, args.wheelhouse, args.target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
