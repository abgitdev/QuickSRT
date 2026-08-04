#!/usr/bin/env python3
"""Validate QuickSRT's host and locked Python runtime contract."""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import platform
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple


Version = Tuple[int, ...]


def parse_version(value: str) -> Version:
    parts: List[int] = []
    for part in value.split("."):
        digits = "".join(character for character in part if character.isdigit())
        if not digits:
            break
        parts.append(int(digits))
    if not parts:
        raise ValueError("invalid version: {}".format(value))
    return tuple(parts)


def version_at_least(actual: str, minimum: str) -> bool:
    actual_parts = parse_version(actual)
    minimum_parts = parse_version(minimum)
    width = max(len(actual_parts), len(minimum_parts))
    return actual_parts + (0,) * (width - len(actual_parts)) >= minimum_parts + (0,) * (width - len(minimum_parts))


def version_less_than(actual: str, maximum: str) -> bool:
    actual_parts = parse_version(actual)
    maximum_parts = parse_version(maximum)
    width = max(len(actual_parts), len(maximum_parts))
    return actual_parts + (0,) * (width - len(actual_parts)) < maximum_parts + (0,) * (width - len(maximum_parts))


def load_policy(path: Path) -> Dict[str, object]:
    with path.open("r", encoding="utf-8") as handle:
        policy = json.load(handle)
    if policy.get("schema_version") != 1:
        raise ValueError("unsupported runtime policy schema")
    return policy


def validate(
    policy: Dict[str, object],
    system: str,
    machine: str,
    macos_version: str,
    python_version: str,
    component_versions: Optional[Dict[str, str]] = None,
    validate_target_python: bool = True,
) -> List[str]:
    errors: List[str] = []
    platform_policy = policy["platform"]
    python_policy = policy["python"]
    assert isinstance(platform_policy, dict)
    assert isinstance(python_policy, dict)

    if system != platform_policy["system"]:
        errors.append("requires {}, found {}".format(platform_policy["system"], system or "unknown OS"))
    if machine != platform_policy["machine"]:
        errors.append("requires native arm64, found {} (Rosetta/x86_64 is not supported)".format(machine or "unknown architecture"))
    if not macos_version or not version_at_least(macos_version, str(platform_policy["minimum_macos"])):
        errors.append("requires macOS {} or newer, found {}".format(platform_policy["minimum_macos"], macos_version or "unknown"))
    python_minimum = str(
        python_policy["minimum"] if validate_target_python else python_policy["bootstrap_minimum"]
    )
    python_maximum = str(python_policy["maximum_exclusive"]) if validate_target_python else None
    if not version_at_least(python_version, python_minimum) or (
        python_maximum is not None and not version_less_than(python_version, python_maximum)
    ):
        errors.append(
            "requires CPython >= {}{}, found {}".format(
                python_minimum,
                ", < {}".format(python_maximum) if python_maximum is not None else "",
                python_version,
            )
        )

    if component_versions is not None:
        components = policy["components"]
        assert isinstance(components, dict)
        for name, expected in sorted(components.items()):
            actual = component_versions.get(name)
            if actual != expected:
                errors.append("requires {}=={}, found {}".format(name, expected, actual or "not installed"))
    return errors


def installed_versions(names: Iterable[str]) -> Dict[str, str]:
    versions: Dict[str, str] = {}
    for name in names:
        try:
            versions[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            pass
    return versions


def pip_target(policy: Dict[str, object]) -> str:
    platform_policy = policy["platform"]
    python_policy = policy["python"]
    assert isinstance(platform_policy, dict)
    assert isinstance(python_policy, dict)
    macos = parse_version(str(platform_policy["minimum_macos"]))
    python = parse_version(str(python_policy["minimum"]))
    return "macosx_{}_{}_arm64 {}{} cp{}{}".format(
        macos[0], macos[1], python[0], python[1], python[0], python[1]
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", required=True, type=Path)
    parser.add_argument("--mode", choices=("bootstrap", "runtime"), default="bootstrap")
    parser.add_argument("--print-pip-target", action="store_true")
    args = parser.parse_args()

    try:
        policy = load_policy(args.policy)
        if args.print_pip_target:
            print(pip_target(policy))
            return 0

        components = policy["components"]
        assert isinstance(components, dict)
        versions = installed_versions(components) if args.mode == "runtime" else None
        system = platform.system()
        machine = platform.machine()
        macos_version = platform.mac_ver()[0]
        python_version = platform.python_version()
        errors = validate(
            policy,
            system,
            machine,
            macos_version,
            python_version,
            versions,
            validate_target_python=args.mode == "runtime",
        )
    except (OSError, ValueError, KeyError, TypeError, AssertionError) as error:
        print("Runtime policy error: {}".format(error), file=sys.stderr)
        return 2

    print("OS: {} {}".format(system, macos_version or "unknown"))
    print("Architecture: {}".format(machine or "unknown"))
    print("Python: {} ({})".format(python_version, sys.executable))
    if versions is not None:
        for name in sorted(components):
            print("{}: {}".format(name, versions.get(name, "not installed")))

    if errors:
        for error in errors:
            print("Compatibility error: {}".format(error), file=sys.stderr)
        return 1

    if args.mode == "runtime":
        try:
            import mlx.core  # noqa: F401
            import mlx_whisper  # noqa: F401
        except Exception as error:
            print("Compatibility error: MLX import failed: {}".format(error), file=sys.stderr)
            return 1

    print("Compatibility: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
