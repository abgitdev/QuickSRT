#!/usr/bin/env python3
"""Make a freshly installed Python target relocatable and integrity-verifiable."""

from __future__ import annotations

import argparse
import csv
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path, PurePosixPath

from privacy_markers import PRIVATE_PATH_MARKERS

PRIVATE_REPLACEMENTS = (
    (PRIVATE_PATH_MARKERS[0], b"/Build/"),
    (PRIVATE_PATH_MARKERS[1], b"/work/"),
    (PRIVATE_PATH_MARKERS[2], b"/private/build/cache/"),
)


def remove_generated_bytecode(root: Path) -> None:
    for path in sorted(root.rglob("__pycache__"), reverse=True):
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
    for path in root.rglob("*.py[co]"):
        path.unlink()


def remove_dangling_symlinks(root: Path) -> None:
    # The python.org framework currently contains optional Tcl/Tk
    # PrivateHeaders links whose targets are not present in the installer. A
    # strict outer app signature rejects those broken resource entries.
    for path in root.rglob("*"):
        if path.is_symlink() and not path.exists():
            path.unlink()


def clean_record(path: Path) -> None:
    rows: list[list[str]] = []
    with path.open(newline="", encoding="utf-8") as handle:
        for row in csv.reader(handle):
            if not row:
                continue
            candidate = row[0].replace("\\", "/")
            pure = PurePosixPath(candidate)
            if pure.is_absolute() or ".." in pure.parts:
                continue
            rows.append(row)
    with path.open("w", newline="", encoding="utf-8") as handle:
        csv.writer(handle, lineterminator="\n").writerows(rows)


def rewrite_console_script(path: Path) -> None:
    data = path.read_bytes()
    if not data.startswith(b"#!"):
        return
    _, separator, remainder = data.partition(b"\n")
    if not separator:
        return
    launcher = (
        b"#!/bin/sh\n"
        b"'''exec' \"$(CDPATH= cd -- \"$(dirname -- \"$0\")/../..\" && pwd -P)/venv/bin/python\" \"$0\" \"$@\"\n"
        b"' '''\n"
    )
    path.write_bytes(launcher + remainder)
    path.chmod(path.stat().st_mode | 0o755)


def replace_private_paths(path: Path) -> None:
    if path.is_symlink() or not path.is_file():
        return
    data = path.read_bytes()
    updated = data
    for old, new in PRIVATE_REPLACEMENTS:
        updated = updated.replace(old, new)
    if updated != data:
        if len(updated) != len(data):
            raise ValueError(f"path sanitation changed file length: {path}")
        path.write_bytes(updated)


def macho_files(root: Path) -> list[Path]:
    matches: list[Path] = []
    for path in root.rglob("*"):
        if path.is_file() and not path.is_symlink():
            result = subprocess.run(
                ["/usr/bin/file", "-b", str(path)],
                check=True,
                stdout=subprocess.PIPE,
                text=True,
            )
            if "Mach-O" in result.stdout:
                matches.append(path)
    return sorted(matches, key=lambda item: len(item.parts), reverse=True)


def macho_architectures(
    path: Path,
    runner: object = subprocess.run,
) -> tuple[str, ...]:
    result = runner(
        ["/usr/bin/lipo", "-archs", str(path)],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    return tuple(result.stdout.split())


def thin_macho_to_arm64(
    path: Path,
    runner: object = subprocess.run,
) -> None:
    architectures = macho_architectures(path, runner)
    if architectures == ("arm64",):
        return
    if "arm64" not in architectures:
        raise ValueError(f"packaged Mach-O lacks arm64: {path}")

    temporary = path.with_name(f".{path.name}.arm64")
    if temporary.exists():
        temporary.unlink()
    try:
        mode = path.stat().st_mode & 0o7777
        runner(
            ["/usr/bin/lipo", str(path), "-thin", "arm64", "-output", str(temporary)],
            check=True,
        )
        temporary.chmod(mode)
        os.replace(temporary, path)
        if macho_architectures(path, runner) != ("arm64",):
            raise ValueError(f"failed to produce arm64-only Mach-O: {path}")
    finally:
        if temporary.exists():
            temporary.unlink()


def remove_known_intel_only_launchers(
    root: Path,
    machos: list[Path],
    runner: object = subprocess.run,
) -> list[Path]:
    retained: list[Path] = []
    for path in machos:
        architectures = macho_architectures(path, runner)
        if "arm64" in architectures:
            retained.append(path)
            continue
        relative = path.relative_to(root).as_posix()
        is_python_intel_launcher = (
            architectures == ("x86_64",)
            and re.fullmatch(
                r"Python\.framework/Versions/(\d+\.\d+)/bin/python\1-intel64",
                relative,
            )
            is not None
        )
        if not is_python_intel_launcher:
            raise ValueError(f"unexpected packaged Mach-O lacks arm64: {path}")
        path.unlink()
    remove_dangling_symlinks(root)
    return retained


def relocate_python_framework(root: Path, machos: list[Path]) -> None:
    versions_root = root / "Python.framework/Versions"
    versions = sorted(
        path for path in versions_root.iterdir()
        if path.is_dir() and not path.is_symlink() and re.fullmatch(r"\d+\.\d+", path.name)
    )
    if len(versions) != 1:
        raise ValueError("expected exactly one packaged Python framework version")
    framework_root = versions[0]
    old_prefix = "/Library/Frameworks/Python.framework/Versions/{}/".format(framework_root.name)
    framework_library = framework_root / "Python"
    for path in machos:
        output = subprocess.run(
            ["/usr/bin/otool", "-L", str(path)],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        ).stdout
        dependencies = [
            match.group(1)
            for line in output.splitlines()[1:]
            if (match := re.match(r"\s+(\S+)\s+\(", line))
        ]
        for dependency in dependencies:
            if not dependency.startswith(old_prefix):
                continue
            target = framework_root / dependency.removeprefix(old_prefix)
            relative = os.path.relpath(target, path.parent)
            replacement = "@loader_path/" + relative
            subprocess.run(
                ["/usr/bin/install_name_tool", "-change", dependency, replacement, str(path)],
                check=True,
                stderr=subprocess.DEVNULL,
            )
    if framework_library in machos:
        subprocess.run(
            ["/usr/bin/install_name_tool", "-id", "@rpath/Python", str(framework_library)],
            check=True,
            stderr=subprocess.DEVNULL,
        )


def run_codesign(command: list[str], description: str) -> None:
    result = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown codesign failure"
        raise ValueError(f"{description}: {detail}")


def is_framework_executable(path: Path, root: Path) -> bool:
    for parent in path.parents:
        if parent == root.parent:
            break
        if parent.suffix == ".framework" and path.name == parent.stem:
            return True
    return False


def sign_macho(root: Path) -> None:
    machos = macho_files(root)
    machos = remove_known_intel_only_launchers(root, machos)
    for path in machos:
        thin_macho_to_arm64(path)
    relocate_python_framework(root, machos)
    for path in machos:
        if is_framework_executable(path, root):
            continue
        run_codesign(
            ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(path)],
            f"failed to sign {path.relative_to(root)}",
        )
        run_codesign(
            ["/usr/bin/codesign", "--verify", "--strict", str(path)],
            f"failed to verify {path.relative_to(root)}",
        )
    nested_bundles = sorted(
        (
            path
            for path in root.rglob("*")
            if path.is_dir()
            and not path.is_symlink()
            and path.suffix in {".app", ".framework"}
            and path != root / "Python.framework"
        ),
        key=lambda item: len(item.parts),
        reverse=True,
    )
    for bundle in nested_bundles:
        run_codesign(
            ["/usr/bin/codesign", "--force", "--deep", "--sign", "-", "--timestamp=none", str(bundle)],
            f"failed to sign bundle {bundle.relative_to(root)}",
        )
        run_codesign(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)],
            f"failed to verify bundle {bundle.relative_to(root)}",
        )
    framework = root / "Python.framework"
    if framework.is_dir():
        run_codesign(
            ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(framework)],
            "failed to sign Python.framework",
        )
        run_codesign(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(framework)],
            "failed to verify Python.framework",
        )


def prepare(root: Path) -> None:
    remove_generated_bytecode(root)
    remove_dangling_symlinks(root)
    for record in root.rglob("*.dist-info/RECORD"):
        clean_record(record)
    bin_dir = root / "site-packages" / "bin"
    if bin_dir.is_dir():
        for path in bin_dir.iterdir():
            if path.is_file() and not path.is_symlink():
                rewrite_console_script(path)
    for path in root.rglob("*"):
        replace_private_paths(path)
    sign_macho(root)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    try:
        prepare(args.root.resolve())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Runtime preparation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
