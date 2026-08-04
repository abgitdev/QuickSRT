#!/usr/bin/env python3
"""Download and atomically install QuickSRT's exact trusted model revision."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import sys
import traceback
import uuid

from model_integrity import load_policy, validate_model, write_manifest


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-id")
    parser.add_argument("--revision")
    parser.add_argument("--models-dir", required=True)
    parser.add_argument("--policy")
    parser.add_argument("--local-only", action="store_true")
    return parser.parse_args()


def is_inside(path: pathlib.Path, root: pathlib.Path) -> bool:
    try:
        path.resolve(strict=False).relative_to(root.resolve(strict=True))
        return True
    except (OSError, ValueError):
        return False


def safe_remove(path: pathlib.Path, root: pathlib.Path) -> None:
    if path.exists() and is_inside(path, root) and path != root:
        shutil.rmtree(path)


def copy_legacy_snapshot(models_dir: pathlib.Path, policy: dict, destination: pathlib.Path) -> bool:
    repo_cache = "models--" + policy["repository_id"].replace("/", "--")
    source = models_dir / repo_cache / "snapshots" / policy["revision"]
    if not source.is_dir():
        return False
    destination.mkdir(parents=True)
    for name in policy["files"]:
        shutil.copy2(source / name, destination / name, follow_symlinks=True)
    return True


def configure_owned_cache(staging: pathlib.Path) -> pathlib.Path:
    cache = staging / "download-cache"
    os.environ["HF_HOME"] = str(cache / "huggingface")
    os.environ["HF_HUB_CACHE"] = str(cache / "huggingface" / "hub")
    os.environ["HF_XET_CACHE"] = str(cache / "xet")
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    return cache


def install_candidate(candidate: pathlib.Path, final: pathlib.Path, models_dir: pathlib.Path) -> None:
    previous = final.with_name(final.name + ".previous")
    if previous.exists() and not final.exists():
        os.replace(previous, final)
    if previous.exists():
        safe_remove(previous, models_dir)
    if final.exists():
        os.replace(final, previous)
    try:
        os.replace(candidate, final)
    except BaseException:
        if previous.exists() and not final.exists():
            os.replace(previous, final)
        raise
    safe_remove(previous, models_dir)


def main() -> int:
    args = parse_args()
    script_root = pathlib.Path(__file__).resolve().parents[1]
    policy_path = pathlib.Path(args.policy).expanduser().resolve() if args.policy else script_root / "Runtime/model-policy.json"
    policy = load_policy(policy_path)
    if args.repo_id and args.repo_id != policy["repository_id"]:
        raise SystemExit("The requested repository is not trusted by the bundled model policy.")
    if args.revision and args.revision != policy["revision"]:
        raise SystemExit("The requested model revision is not trusted by the bundled model policy.")

    models_dir = pathlib.Path(args.models_dir).expanduser().resolve()
    models_dir.mkdir(parents=True, exist_ok=True)
    managed_root = models_dir / "managed"
    managed_root.mkdir(exist_ok=True)
    final = managed_root / policy["revision"]
    staging = models_dir / f"download-{uuid.uuid4().hex}.incomplete"
    candidate = staging / "model"

    try:
        if final.is_dir():
            validate_model(final, policy, require_manifest=True)
            print("MODEL_READY", flush=True)
            print(f"Verified pinned revision {policy['revision']}.", flush=True)
            return 0

        staging.mkdir()
        configure_owned_cache(staging)
        print(f"Model: {policy['repository_id']}", flush=True)
        print(f"Pinned revision: {policy['revision']}", flush=True)
        print("Downloading into an isolated temporary directory...", flush=True)

        copied = copy_legacy_snapshot(models_dir, policy, candidate)
        if not copied:
            try:
                from huggingface_hub import snapshot_download
            except BaseException as error:
                raise RuntimeError("huggingface_hub is unavailable in the packaged runtime") from error
            snapshot_download(
                repo_id=policy["repository_id"],
                revision=policy["revision"],
                local_dir=str(candidate),
                allow_patterns=sorted(policy["files"]),
                local_files_only=args.local_only,
            )
            local_metadata = candidate / ".cache"
            if local_metadata.exists():
                shutil.rmtree(local_metadata)

        # Hash, exact file set, config schema, and every NPY header are checked
        # before MLX is ever allowed to deserialize the NPZ archive.
        validate_model(candidate, policy, require_manifest=False)
        write_manifest(candidate, policy)
        validate_model(candidate, policy, require_manifest=True)
        install_candidate(candidate, final, models_dir)
        validate_model(final, policy, require_manifest=True)

        # Remove the legacy Hugging Face cache only after the direct, verified
        # model directory is durably installed. Staging cache and Xet logs are
        # removed in the finally block below.
        legacy = models_dir / ("models--" + policy["repository_id"].replace("/", "--"))
        safe_remove(legacy, models_dir)

        print("MODEL_READY", flush=True)
        print("The exact trusted model revision was atomically installed.", flush=True)
        return 0
    except BaseException:
        traceback.print_exc()
        return 1
    finally:
        safe_remove(staging, models_dir)


if __name__ == "__main__":
    raise SystemExit(main())
