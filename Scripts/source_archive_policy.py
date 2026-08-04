#!/usr/bin/env python3
"""Fail closed when a source zip contains local credentials or secret material."""

from __future__ import annotations

import argparse
import re
import sys
import zipfile
from pathlib import PurePosixPath


FORBIDDEN_BASENAMES = {
    ".netrc",
    "_netrc",
    ".npmrc",
    ".pypirc",
    "credentials",
    "credentials.json",
    "secrets.json",
    "service-account.json",
    "id_rsa",
    "id_dsa",
    "id_ecdsa",
    "id_ed25519",
}
MAX_SCANNED_FILE_BYTES = 8 * 1_024 * 1_024
PRIVATE_KEY_MARKER = b"-----BEGIN " + b"PRIVATE KEY-----"
OPENSSH_KEY_MARKER = b"-----BEGIN OPENSSH " + b"PRIVATE KEY-----"
AWS_ACCESS_KEY = re.compile(b"AK" + b"IA" + b"[0-9A-Z]{16}")
GITHUB_TOKEN = re.compile(b"gh" + b"[ps]_[A-Za-z0-9]{30,}")
GITHUB_FINE_GRAINED_TOKEN = re.compile(b"github_pat" + b"_[A-Za-z0-9_]{30,}")


def failures(archive: zipfile.ZipFile) -> list[str]:
    issues: list[str] = []
    for info in archive.infolist():
        if info.is_dir():
            continue
        path = PurePosixPath(info.filename)
        if path.name.casefold() in FORBIDDEN_BASENAMES:
            issues.append(f"credential filename: {info.filename}")
        if info.file_size > MAX_SCANNED_FILE_BYTES:
            continue
        data = archive.read(info)
        if PRIVATE_KEY_MARKER in data or OPENSSH_KEY_MARKER in data:
            issues.append(f"private key material: {info.filename}")
        elif AWS_ACCESS_KEY.search(data):
            issues.append(f"AWS access key material: {info.filename}")
        elif GITHUB_TOKEN.search(data) or GITHUB_FINE_GRAINED_TOKEN.search(data):
            issues.append(f"GitHub token material: {info.filename}")
    return issues


def verify(path: str) -> None:
    with zipfile.ZipFile(path) as archive:
        issues = failures(archive)
    if issues:
        raise ValueError("source archive credential policy failed:\n" + "\n".join(issues[:100]))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive")
    args = parser.parse_args()
    try:
        verify(args.archive)
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        print(error, file=sys.stderr)
        return 1
    print("Source archive credential policy: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
