#!/usr/bin/env python3
"""Generate a reproducible CycloneDX SBOM from the locked release wheels."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import zipfile
from email.parser import BytesParser
from pathlib import Path


def canonical_name(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def lock_hashes(path: Path) -> dict[tuple[str, str], set[str]]:
    result: dict[tuple[str, str], set[str]] = {}
    current: tuple[str, str] | None = None
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^([A-Za-z0-9_.-]+)==([^\s\\]+)", line)
        if match:
            current = (canonical_name(match.group(1)), match.group(2))
            result.setdefault(current, set())
        hash_match = re.search(r"--hash=sha256:([0-9a-f]{64})", line)
        if hash_match and current:
            result[current].add(hash_match.group(1))
    return result


def wheel_metadata(path: Path):
    with zipfile.ZipFile(path) as archive:
        names = [name for name in archive.namelist() if name.endswith(".dist-info/METADATA") and name.count("/") == 1]
        if len(names) != 1:
            raise ValueError(f"ambiguous wheel metadata: {path.name}")
        return BytesParser().parsebytes(archive.read(names[0]))


LICENSE_NORMALIZATION = {
    "Apache Software License": "Apache-2.0",
    "BSD License": "BSD-3-Clause",
    "MIT License": "MIT",
    "Mozilla Public License 2.0 (MPL 2.0)": "MPL-2.0",
}

# Exact locked releases whose shipped license text is more specific than
# their legacy Trove classifier. Lock hashes bind each override to the
# inspected wheel; a version change requires a fresh license review.
VERIFIED_LICENSE_OVERRIDES = {
    ("numba", "0.66.0"): "BSD-2-Clause",
}


def license_expression(metadata, name: str, version: str) -> str | None:
    override = VERIFIED_LICENSE_OVERRIDES.get((canonical_name(name), version))
    if override:
        return override
    expression = metadata.get("License-Expression")
    if expression:
        return expression.strip()
    classifiers = metadata.get_all("Classifier", [])
    licenses = [item.split(" :: ")[-1] for item in classifiers if item.startswith("License ::")]
    if licenses:
        normalized = [LICENSE_NORMALIZATION.get(item, item) for item in licenses]
        return " AND ".join(sorted(set(normalized)))
    legacy = metadata.get("License")
    if not legacy:
        return None
    legacy = legacy.strip()
    if legacy.startswith("MIT License"):
        return "MIT"
    return LICENSE_NORMALIZATION.get(legacy, legacy) if len(legacy) <= 100 and legacy != "UNKNOWN" else None


def generate(lock: Path, wheelhouse: Path) -> dict[str, object]:
    expected = lock_hashes(lock)
    components = []
    found: set[tuple[str, str]] = set()
    for wheel in sorted(wheelhouse.glob("*.whl")):
        metadata = wheel_metadata(wheel)
        name = canonical_name(metadata["Name"])
        version = metadata["Version"]
        identity = (name, version)
        digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
        if digest not in expected.get(identity, set()):
            raise ValueError(f"wheel is not in lock: {wheel.name}")
        found.add(identity)
        component: dict[str, object] = {
            "type": "library",
            "bom-ref": f"pkg:pypi/{name}@{version}",
            "name": name,
            "version": version,
            "purl": f"pkg:pypi/{name}@{version}",
            "hashes": [{"alg": "SHA-256", "content": digest}],
        }
        expression = license_expression(metadata, name, version)
        if expression:
            component["licenses"] = [{"expression": expression}]
        components.append(component)

    missing = sorted(set(expected) - found)
    if missing:
        raise ValueError(f"locked wheels missing from SBOM input: {missing}")
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": "urn:uuid:7f55c39c-b68f-5c50-9ce5-13fa95cfbbd4",
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "bom-ref": "pkg:github/abgitdev/QuickSRT",
                "name": "QuickSRT release Python runtime",
            }
        },
        "components": sorted(components, key=lambda item: item["name"]),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--wheelhouse", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    document = generate(args.lock, args.wheelhouse)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
