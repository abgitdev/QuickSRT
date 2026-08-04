#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="$ROOT_DIR/Runtime/Support/venv/bin/python"
RAW_PYTHON="$ROOT_DIR/Runtime/Support/Python.framework/Versions/Current/bin/python3"
PYTHON_HOME="$ROOT_DIR/Runtime/Support/Python.framework/Versions/Current"
RUNTIME_PACKAGES="$ROOT_DIR/Runtime/Support/site-packages"
LOCK="$ROOT_DIR/Runtime/requirements.lock"
AUDIT_LOCK="$ROOT_DIR/Runtime/audit-requirements.lock"
WORK_DIR="$(mktemp -d /tmp/quicksrt-pip-audit.XXXXXX)"
AUDIT_TARGET="$WORK_DIR/site-packages"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

[[ -x "$PYTHON" ]] || { echo "Build Runtime/Support before auditing." >&2; exit 1; }
mkdir -p "$AUDIT_TARGET"
"$PYTHON" -m pip install \
  --disable-pip-version-check \
  --no-cache-dir \
  --require-hashes \
  --target "$AUDIT_TARGET" \
  --requirement "$AUDIT_LOCK"

PYTHONHOME="$PYTHON_HOME" PYTHONPATH="$AUDIT_TARGET:$RUNTIME_PACKAGES" \
  PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 "$RAW_PYTHON" -m pip_audit \
  --require-hashes \
  --no-deps \
  --disable-pip \
  --progress-spinner off \
  --requirement "$LOCK"
