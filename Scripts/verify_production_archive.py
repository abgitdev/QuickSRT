#!/usr/bin/env python3
"""Fail-closed inspection for a local QuickSRT production xcarchive."""

from __future__ import annotations

import argparse
import plistlib
import re
import subprocess
import sys
from pathlib import Path

from privacy_markers import PRIVATE_PATH_MARKERS, contains_private_marker


EXPECTED_IDENTIFIER = "local.quicksrt.app"
EXPECTED_DEPLOYMENT_TARGET = "15.0"
EXPECTED_ARCHITECTURE = "arm64"
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}
FORBIDDEN_SUFFIXES = {
    ".xctest",
    ".profraw",
    ".profdata",
    ".gcda",
    ".gcno",
    ".pyc",
    ".pyo",
    ".swiftmodule",
    ".swiftdoc",
    ".swiftinterface",
    ".abi.json",
}
FORBIDDEN_NAME_MARKERS = {
    "quicksrttests",
    "project_memory",
    "_project_audit",
    "_project_research",
    "_private_chats",
    "deriveddata",
    "default.profraw",
}


def run(command: list[str]) -> str:
    return subprocess.run(
        command,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout


def read_plist(path: Path) -> dict[str, object]:
    with path.open("rb") as handle:
        value = plistlib.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"plist is not a dictionary: {path}")
    return value


def is_macho(path: Path) -> bool:
    if not path.is_file() or path.is_symlink():
        return False
    with path.open("rb") as handle:
        return handle.read(4) in MACHO_MAGICS


def is_static_archive(path: Path) -> bool:
    if not path.is_file() or path.is_symlink() or path.suffix != ".a":
        return False
    with path.open("rb") as handle:
        return handle.read(8) == b"!<arch>\n"


def is_native_code(path: Path) -> bool:
    return is_macho(path) or is_static_archive(path)


def structural_failures(archive: Path, app: Path) -> list[str]:
    failures: list[str] = []
    products = archive / "Products"
    applications = products / "Applications"
    if not applications.is_dir():
        return ["archive is missing Products/Applications"]

    product_entries = sorted(path.name for path in products.iterdir())
    if product_entries != ["Applications"]:
        failures.append(f"unexpected Products entries: {product_entries}")
    application_entries = sorted(path.name for path in applications.iterdir())
    if application_entries != ["QuickSRT.app"]:
        failures.append(f"unexpected archived applications: {application_entries}")

    for path in archive.rglob("*"):
        relative = path.relative_to(archive).as_posix()
        name = path.name.casefold()
        if path.name == ".DS_Store":
            failures.append(f"machine-generated metadata: {relative}")
        if any(name.endswith(suffix) for suffix in FORBIDDEN_SUFFIXES):
            failures.append(f"test/profiling/debug artifact: {relative}")
        if any(marker in name for marker in FORBIDDEN_NAME_MARKERS):
            failures.append(f"private or build-only artifact: {relative}")
        if path.is_dir() and path.suffix == ".dSYM":
            try:
                path.relative_to(app)
            except ValueError:
                pass
            else:
                failures.append(f"dSYM must remain outside the application: {relative}")
    return failures


def privacy_failures(root: Path) -> list[str]:
    failures: list[str] = []
    for path in root.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        for marker in PRIVATE_PATH_MARKERS:
            if contains_private_marker(path, marker):
                failures.append(
                    f"private machine path {marker.decode()!r}: {path.relative_to(root)}"
                )
                break
    return failures


def metadata_failures(archive: Path, app: Path) -> list[str]:
    failures: list[str] = []
    archive_info = read_plist(archive / "Info.plist")
    app_info = read_plist(app / "Contents/Info.plist")
    properties = archive_info.get("ApplicationProperties")
    if not isinstance(properties, dict):
        return ["archive ApplicationProperties are missing or malformed"]

    expected_properties: dict[str, object] = {
        "ApplicationPath": "Applications/QuickSRT.app",
        "Architectures": [EXPECTED_ARCHITECTURE],
        "CFBundleIdentifier": EXPECTED_IDENTIFIER,
    }
    for key, expected in expected_properties.items():
        if properties.get(key) != expected:
            failures.append(
                f"archive metadata {key}: expected {expected!r}, got {properties.get(key)!r}"
            )

    expected_app_values = {
        "CFBundleIdentifier": EXPECTED_IDENTIFIER,
        "CFBundleExecutable": "QuickSRT",
        "LSMinimumSystemVersion": EXPECTED_DEPLOYMENT_TARGET,
    }
    for key, expected in expected_app_values.items():
        if app_info.get(key) != expected:
            failures.append(f"app metadata {key}: expected {expected!r}, got {app_info.get(key)!r}")

    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        value = app_info.get(key)
        if not isinstance(value, str) or not value:
            failures.append(f"app metadata {key} is missing")
        elif properties.get(key) != value:
            failures.append(f"archive metadata {key} does not match the application")
    return failures


def macho_failures(archive: Path, app: Path) -> tuple[list[str], int]:
    failures: list[str] = []
    checked = 0
    main_executable = app / "Contents/MacOS/QuickSRT"
    if not is_macho(main_executable):
        return ["QuickSRT main executable is missing or is not Mach-O"], checked

    for path in sorted(path for path in archive.rglob("*") if is_native_code(path)):
        checked += 1
        relative = path.relative_to(archive)
        architectures = tuple(run(["/usr/bin/lipo", "-archs", str(path)]).split())
        if architectures != (EXPECTED_ARCHITECTURE,):
            failures.append(f"non-arm64-only native code {relative}: {architectures}")
        if is_macho(path):
            linked = run(["/usr/bin/otool", "-L", str(path)]).casefold()
            if "xctest" in linked:
                failures.append(f"XCTest linkage in production Mach-O: {relative}")
            load_commands = run(["/usr/bin/otool", "-l", str(path)])
            minimum = deployment_target(load_commands)
            if minimum is None:
                failures.append(f"missing macOS deployment target in Mach-O: {relative}")
            elif version_tuple(minimum) > version_tuple(EXPECTED_DEPLOYMENT_TARGET):
                failures.append(
                    f"Mach-O requires macOS {minimum} above app target "
                    f"{EXPECTED_DEPLOYMENT_TARGET}: {relative}"
                )

    main_minimum = deployment_target(run(["/usr/bin/otool", "-l", str(main_executable)]))
    if main_minimum != EXPECTED_DEPLOYMENT_TARGET:
        failures.append(
            "main executable deployment target: expected "
            f"{EXPECTED_DEPLOYMENT_TARGET}, got {main_minimum or '<missing>'}"
        )

    debug_info = run(["/usr/bin/dwarfdump", "--debug-info", str(main_executable)])
    if re.search(r"^0x[0-9a-fA-F]+:", debug_info, re.MULTILINE):
        failures.append("main executable still contains DWARF debug records")
    return failures, checked


def deployment_target(load_commands: str) -> str | None:
    build_version = re.search(
        r"\bcmd LC_BUILD_VERSION\b.*?\bplatform\s+(?:macos|1)\b.*?\bminos\s+(\S+)",
        load_commands,
        re.DOTALL,
    )
    if build_version:
        return build_version.group(1)
    legacy = re.search(
        r"\bcmd LC_VERSION_MIN_MACOSX\b.*?\bversion\s+(\S+)",
        load_commands,
        re.DOTALL,
    )
    return legacy.group(1) if legacy else None


def version_tuple(value: str) -> tuple[int, ...]:
    if not re.fullmatch(r"\d+(?:\.\d+)*", value):
        raise ValueError(f"invalid deployment target: {value!r}")
    return tuple(int(component) for component in value.split("."))


def uuid_set(path: Path) -> set[tuple[str, str]]:
    output = run(["/usr/bin/dwarfdump", "--uuid", str(path)])
    return {
        (match.group(1).upper(), match.group(2))
        for match in re.finditer(r"UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)", output)
    }


def dsym_failures(archive: Path, app: Path) -> list[str]:
    failures: list[str] = []
    dsym_root = archive / "dSYMs"
    dsyms = sorted(dsym_root.glob("*.dSYM")) if dsym_root.is_dir() else []
    if [path.name for path in dsyms] != ["QuickSRT.app.dSYM"]:
        return [f"expected exactly QuickSRT.app.dSYM outside the app, got {[p.name for p in dsyms]}"]
    main_executable = app / "Contents/MacOS/QuickSRT"
    app_uuids = uuid_set(main_executable)
    dsym_uuids = uuid_set(dsyms[0])
    if len(app_uuids) != 1 or any(architecture != EXPECTED_ARCHITECTURE for _, architecture in app_uuids):
        failures.append(f"unexpected application UUID architecture set: {sorted(app_uuids)}")
    if not app_uuids or dsym_uuids != app_uuids:
        failures.append(f"dSYM UUIDs do not match the application: app={app_uuids}, dSYM={dsym_uuids}")
    return failures


def verify(archive: Path) -> tuple[int, str, str]:
    archive = archive.resolve()
    app = archive / "Products/Applications/QuickSRT.app"
    if not archive.is_dir() or not app.is_dir():
        raise ValueError(f"not a QuickSRT xcarchive: {archive}")

    failures: list[str] = []
    failures.extend(structural_failures(archive, app))
    failures.extend(metadata_failures(archive, app))
    failures.extend(privacy_failures(app))
    macho_issues, macho_count = macho_failures(archive, app)
    failures.extend(macho_issues)
    failures.extend(dsym_failures(archive, app))
    if failures:
        raise ValueError("production archive verification failed:\n" + "\n".join(failures[:100]))

    info = read_plist(app / "Contents/Info.plist")
    return macho_count, str(info["CFBundleShortVersionString"]), str(info["CFBundleVersion"])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    try:
        macho_count, version, build = verify(args.archive)
    except (
        OSError,
        ValueError,
        KeyError,
        plistlib.InvalidFileException,
        subprocess.CalledProcessError,
    ) as error:
        print(error, file=sys.stderr)
        return 1
    print(
        f"Verified production archive: QuickSRT {version} ({build}), "
        f"{macho_count} arm64-only native-code files, macOS {EXPECTED_DEPLOYMENT_TARGET}, "
        "matched external dSYM, no test/profiling artifacts or private paths in the app."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
