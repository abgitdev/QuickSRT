#!/usr/bin/env python3
import json
import pathlib
import re
import sys

from generate_runtime_sbom import canonical_name, lock_hashes


ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCK = ROOT / "Runtime" / "requirements.lock"
INVENTORY = ROOT / "PYTHON_DEPENDENCY_LICENSES.md"
SBOM = ROOT / "Runtime" / "runtime-sbom.cdx.json"


def normalize(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def read_lock(path=LOCK):
    entries = {}
    pattern = re.compile(r"^([A-Za-z0-9_.-]+)==([^\s\\]+)")
    for line in path.read_text(encoding="utf-8").splitlines():
        match = pattern.match(line)
        if match:
            entries[normalize(match.group(1))] = match.group(2)
    return entries


def read_inventory(path=INVENTORY):
    entries = {}
    pattern = re.compile(
        r"^\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|"
    )
    for line in path.read_text(encoding="utf-8").splitlines():
        match = pattern.match(line)
        if not match or match.group(1).strip() in {"Package", "---"}:
            continue
        name = normalize(match.group(1).strip())
        version = match.group(2).strip()
        license_expression = match.group(3).strip().split(";", 1)[0].strip()
        if name in entries:
            raise ValueError(f"duplicate inventory entry: {name}")
        entries[name] = (version, license_expression)
    return entries


def validate(lock=LOCK, inventory=INVENTORY, sbom=SBOM):
    locked = read_lock(lock)
    locked_hashes = lock_hashes(lock)
    documented = read_inventory(inventory)
    errors = []

    for name in sorted(locked.keys() - documented.keys()):
        errors.append(f"missing from inventory: {name}=={locked[name]}")
    for name in sorted(documented.keys() - locked.keys()):
        errors.append(f"not present in lock: {name}=={documented[name][0]}")
    for name in sorted(locked.keys() & documented.keys()):
        if locked[name] != documented[name][0]:
            errors.append(
                f"version mismatch for {name}: lock={locked[name]}, "
                f"inventory={documented[name][0]}"
            )

    try:
        document = json.loads(sbom.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return errors + [f"could not read SBOM: {error}"]
    if document.get("bomFormat") != "CycloneDX" or document.get("specVersion") != "1.6":
        errors.append("SBOM must be CycloneDX 1.6")
    components = document.get("components")
    if not isinstance(components, list):
        return errors + ["SBOM components are missing or malformed"]

    seen = set()
    for component in components:
        if not isinstance(component, dict):
            errors.append("SBOM contains a malformed component")
            continue
        name = canonical_name(str(component.get("name", "")))
        version = str(component.get("version", ""))
        if not name or name in seen:
            errors.append(f"duplicate or missing SBOM component name: {name!r}")
            continue
        seen.add(name)
        if name not in locked:
            errors.append(f"SBOM component is not locked: {name}=={version}")
            continue
        if version != locked[name]:
            errors.append(f"SBOM version mismatch for {name}: lock={locked[name]}, sbom={version}")
        expected_reference = f"pkg:pypi/{name}@{version}"
        if component.get("purl") != expected_reference or component.get("bom-ref") != expected_reference:
            errors.append(f"SBOM package reference mismatch for {name}")

        hashes = component.get("hashes")
        sha256_values = {
            item.get("content")
            for item in hashes
            if isinstance(item, dict) and item.get("alg") == "SHA-256"
        } if isinstance(hashes, list) else set()
        if (
            len(sha256_values) != 1
            or not sha256_values <= locked_hashes.get((name, version), set())
        ):
            errors.append(f"SBOM wheel hash is not present in the lock for {name}=={version}")

        expected_license = documented.get(name, ("", ""))[1]
        licenses = component.get("licenses")
        expressions = {
            item.get("expression")
            for item in licenses
            if isinstance(item, dict) and isinstance(item.get("expression"), str)
        } if isinstance(licenses, list) else set()
        if expressions != {expected_license}:
            errors.append(
                f"SBOM license mismatch for {name}: inventory={expected_license!r}, "
                f"sbom={sorted(expressions)!r}"
            )

    for name in sorted(set(locked) - seen):
        errors.append(f"missing from SBOM: {name}=={locked[name]}")
    return errors


def main():
    locked = read_lock()
    errors = validate()
    if errors:
        print("Python dependency license inventory or SBOM is out of date:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(
        f"Python license inventory and CycloneDX SBOM match {len(locked)} locked packages."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
