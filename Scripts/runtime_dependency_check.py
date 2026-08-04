#!/usr/bin/env python3
"""Check the complete runtime dependency graph and the Torch VEX exception."""

from __future__ import annotations

import ast
import importlib.metadata
import json
import pathlib
import sys

from packaging.requirements import Requirement
from packaging.version import Version


ALLOWED_MISSING = {("mlx-whisper", "torch")}


def normalized(name: str) -> str:
    return name.lower().replace("_", "-").replace(".", "-")


def installed_versions() -> dict[str, str]:
    return {
        normalized(distribution.metadata["Name"]): distribution.version
        for distribution in importlib.metadata.distributions()
        if distribution.metadata.get("Name")
    }


def check_metadata() -> list[str]:
    versions = installed_versions()
    errors: list[str] = []
    if "torch" in versions:
        errors.append("Torch must not be present in the QuickSRT release runtime")

    for distribution in importlib.metadata.distributions():
        parent = normalized(distribution.metadata.get("Name", ""))
        for raw_requirement in distribution.requires or []:
            requirement = Requirement(raw_requirement)
            if requirement.marker and not requirement.marker.evaluate():
                continue
            dependency = normalized(requirement.name)
            actual = versions.get(dependency)
            if actual is None:
                if (parent, dependency) not in ALLOWED_MISSING:
                    errors.append(f"{parent} requires missing {dependency}")
                continue
            if requirement.specifier and Version(actual) not in requirement.specifier:
                errors.append(
                    f"{parent} requires {dependency}{requirement.specifier}, found {actual}"
                )
    return errors


def check_torch_route() -> list[str]:
    errors: list[str] = []
    distribution = importlib.metadata.distribution("mlx-whisper")
    package_root = pathlib.Path(distribution.locate_file("mlx_whisper"))
    allowed_file = package_root / "torch_whisper.py"
    torch_importers: list[pathlib.Path] = []

    for source in sorted(package_root.rglob("*.py")):
        tree = ast.parse(source.read_text(encoding="utf-8"), filename=str(source))
        imports_torch = any(
            (isinstance(node, ast.Import) and any(alias.name == "torch" or alias.name.startswith("torch.") for alias in node.names))
            or (isinstance(node, ast.ImportFrom) and node.module is not None and (node.module == "torch" or node.module.startswith("torch.")))
            for node in ast.walk(tree)
        )
        if imports_torch:
            torch_importers.append(source)

    if torch_importers != [allowed_file]:
        relative = [str(path.relative_to(package_root)) for path in torch_importers]
        errors.append(f"unexpected mlx-whisper Torch import route(s): {relative}")

    import mlx_whisper  # noqa: F401 -- import without Torch is the dynamic route check

    return errors


def main() -> int:
    errors: list[str] = []
    try:
        errors.extend(check_metadata())
        errors.extend(check_torch_route())
    except Exception as error:
        errors.append(str(error))

    if errors:
        for error in errors:
            print(f"Runtime dependency error: {error}", file=sys.stderr)
        return 1

    print("Runtime dependency graph: OK (Torch excluded by verified production route)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
