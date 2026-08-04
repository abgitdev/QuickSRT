#!/usr/bin/env python3
"""Collect privacy-safe host and application compatibility evidence."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable, Dict, Iterable, Mapping, Optional, Sequence, Tuple


SCHEMA_VERSION = 1
MINIMUM_MACOS = "15.0"
CommandResult = Tuple[int, str, str]
CommandRunner = Callable[[Sequence[str]], CommandResult]


def run_command(arguments: Sequence[str]) -> CommandResult:
    completed = subprocess.run(
        list(arguments),
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.returncode, completed.stdout.strip(), completed.stderr.strip()


def version_parts(value: str) -> Tuple[int, ...]:
    match = re.match(r"^(\d+(?:\.\d+)*)", value.strip())
    if not match:
        return ()
    return tuple(int(part) for part in match.group(1).split("."))


def version_at_least(actual: str, minimum: str) -> bool:
    actual_parts = version_parts(actual)
    minimum_parts = version_parts(minimum)
    if not actual_parts or not minimum_parts:
        return False
    width = max(len(actual_parts), len(minimum_parts))
    return actual_parts + (0,) * (width - len(actual_parts)) >= minimum_parts + (0,) * (
        width - len(minimum_parts)
    )


def required_output(runner: CommandRunner, arguments: Sequence[str], label: str) -> str:
    returncode, stdout, stderr = runner(arguments)
    if returncode != 0 or not stdout:
        detail = stderr or "command returned no output"
        raise RuntimeError("{}: {}".format(label, detail))
    return stdout


def optional_output(runner: CommandRunner, arguments: Sequence[str]) -> Optional[str]:
    returncode, stdout, _ = runner(arguments)
    if returncode != 0 or not stdout:
        return None
    return stdout


def collect_host_evidence(
    runner: CommandRunner = run_command,
    environment: Mapping[str, str] = os.environ,
    test_rosetta_execution: bool = False,
) -> Dict[str, object]:
    architecture = required_output(runner, ["/usr/bin/uname", "-m"], "architecture probe")
    macos_version = required_output(
        runner, ["/usr/bin/sw_vers", "-productVersion"], "macOS version probe"
    )
    macos_build = required_output(
        runner, ["/usr/bin/sw_vers", "-buildVersion"], "macOS build probe"
    )
    memory_text = required_output(
        runner, ["/usr/sbin/sysctl", "-n", "hw.memsize"], "memory probe"
    )
    try:
        memory_bytes = int(memory_text)
    except ValueError as error:
        raise RuntimeError("memory probe returned a non-integer value") from error

    rosetta_receipt = runner(
        ["/usr/sbin/pkgutil", "--pkg-info", "com.apple.pkg.RosettaUpdateAuto"]
    )[0] == 0
    rosetta_execution = None
    if test_rosetta_execution:
        rosetta_execution = runner(["/usr/bin/arch", "-x86_64", "/usr/bin/true"])[0] == 0

    github_actions = environment.get("GITHUB_ACTIONS", "").lower() == "true"
    ci_evidence: Dict[str, object] = {"provider": "github-actions" if github_actions else "local"}
    if github_actions:
        for output_key, environment_key in (
            ("runner_architecture", "RUNNER_ARCH"),
            ("image_os", "ImageOS"),
            ("image_version", "ImageVersion"),
        ):
            value = environment.get(environment_key)
            if value:
                ci_evidence[output_key] = value

    return {
        "schema_version": SCHEMA_VERSION,
        "host": {
            "architecture": architecture,
            "chip": optional_output(runner, ["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"]),
            "model_identifier": optional_output(runner, ["/usr/sbin/sysctl", "-n", "hw.model"]),
            "memory_bytes": memory_bytes,
            "memory_gib": round(memory_bytes / (1024**3), 2),
        },
        "os": {
            "name": "macOS",
            "version": macos_version,
            "build": macos_build,
        },
        "rosetta": {
            "receipt_present": rosetta_receipt,
            "x86_64_execution_tested": test_rosetta_execution,
            "x86_64_execution_available": rosetta_execution,
        },
        "ci": ci_evidence,
        "policy": {
            "minimum_macos": MINIMUM_MACOS,
            "native_arm64_required": True,
            "host_meets_minimum_macos": version_at_least(macos_version, MINIMUM_MACOS),
            "host_is_native_arm64": architecture == "arm64",
        },
        "privacy": {
            "contains_user_name": False,
            "contains_computer_name": False,
            "contains_serial_or_hardware_uuid": False,
            "contains_absolute_paths": False,
        },
    }


def classify_signature(returncode: int, details: str) -> Tuple[str, bool]:
    if returncode != 0:
        return "unsigned", False
    if "Signature=adhoc" in details:
        signature = "ad-hoc"
    elif "Authority=Developer ID Application" in details:
        signature = "developer-id-application"
    else:
        signature = "other"
    timestamp_match = re.search(r"^Timestamp=(.+)$", details, re.MULTILINE)
    has_secure_timestamp = bool(
        timestamp_match and timestamp_match.group(1).strip().lower() not in {"none", ""}
    )
    return signature, has_secure_timestamp


def regular_files(root: Path) -> Iterable[Path]:
    for directory, names, filenames in os.walk(root, followlinks=False):
        names[:] = sorted(name for name in names if not (Path(directory) / name).is_symlink())
        for filename in sorted(filenames):
            path = Path(directory) / filename
            if path.is_file() and not path.is_symlink():
                yield path


def inspect_application(app: Path, runner: CommandRunner = run_command) -> Dict[str, object]:
    app = app.resolve()
    info_path = app / "Contents" / "Info.plist"
    if app.suffix != ".app" or not info_path.is_file():
        raise RuntimeError("application probe requires a valid .app bundle")
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)

    executable_name = info.get("CFBundleExecutable")
    executable = app / "Contents" / "MacOS" / str(executable_name or "")
    if not executable.is_file():
        raise RuntimeError("application bundle has no declared executable")

    macho_count = 0
    unexpected_architectures = []
    for path in regular_files(app):
        returncode, description, _ = runner(["/usr/bin/file", "-b", str(path)])
        if returncode != 0 or "Mach-O" not in description:
            continue
        macho_count += 1
        returncode, architectures, _ = runner(["/usr/bin/lipo", "-archs", str(path)])
        architecture_set = set(architectures.split()) if returncode == 0 else set()
        if architecture_set != {"arm64"}:
            unexpected_architectures.append(
                {
                    "relative_path": path.relative_to(app).as_posix(),
                    "architectures": sorted(architecture_set),
                }
            )

    signature_returncode, signature_stdout, signature_stderr = runner(
        ["/usr/bin/codesign", "-d", "--verbose=4", str(app)]
    )
    signature_kind, secure_timestamp = classify_signature(
        signature_returncode, "\n".join((signature_stdout, signature_stderr))
    )
    stapled = runner(["/usr/bin/xcrun", "stapler", "validate", str(app)])[0] == 0
    local_policy_accepted = (
        runner(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", str(app)])[0]
        == 0
    )

    return {
        "bundle_identifier": info.get("CFBundleIdentifier"),
        "marketing_version": info.get("CFBundleShortVersionString"),
        "build_number": info.get("CFBundleVersion"),
        "minimum_macos": info.get("LSMinimumSystemVersion"),
        "main_executable_architectures": required_output(
            runner, ["/usr/bin/lipo", "-archs", str(executable)], "application architecture probe"
        ).split(),
        "macho_file_count": macho_count,
        "all_macho_files_arm64_only": macho_count > 0 and not unexpected_architectures,
        "unexpected_macho_architectures": unexpected_architectures,
        "security": {
            "signature": signature_kind,
            "secure_timestamp": secure_timestamp,
            "notarization_ticket_stapled": stapled,
            "local_policy_assessment_accepted": local_policy_accepted,
            "downloaded_quarantined_archive_tested": False,
        },
    }


def atomic_write_json(path: Path, evidence: Mapping[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".compatibility-", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(evidence, handle, ensure_ascii=True, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="Optional QuickSRT.app to inspect")
    parser.add_argument("--output", type=Path, help="Write JSON atomically to this path")
    parser.add_argument("--expect-macos-major", help="Fail unless this macOS major version is running")
    parser.add_argument(
        "--require-arm64",
        action="store_true",
        help="Fail unless the host and every inspected app Mach-O are arm64-only",
    )
    parser.add_argument(
        "--test-rosetta-execution",
        action="store_true",
        help="Explicitly try x86_64 execution; omitted by default to avoid changing a clean host",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        evidence = collect_host_evidence(test_rosetta_execution=arguments.test_rosetta_execution)
        host = evidence["host"]
        os_evidence = evidence["os"]
        if arguments.require_arm64 and host["architecture"] != "arm64":
            raise RuntimeError("expected a native arm64 host, found {}".format(host["architecture"]))
        if arguments.expect_macos_major:
            actual_major = version_parts(str(os_evidence["version"]))
            if not actual_major or str(actual_major[0]) != arguments.expect_macos_major:
                raise RuntimeError(
                    "expected macOS major {}, found {}".format(
                        arguments.expect_macos_major, os_evidence["version"]
                    )
                )
        if arguments.app:
            application = inspect_application(arguments.app)
            evidence["application"] = application
            if arguments.require_arm64 and not application["all_macho_files_arm64_only"]:
                raise RuntimeError("inspected application contains a non-arm64-only Mach-O file")
        rendered = json.dumps(evidence, ensure_ascii=True, indent=2, sort_keys=True) + "\n"
        if arguments.output:
            atomic_write_json(arguments.output, evidence)
        sys.stdout.write(rendered)
        return 0
    except (OSError, RuntimeError, plistlib.InvalidFileException) as error:
        print("Compatibility evidence error: {}".format(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
