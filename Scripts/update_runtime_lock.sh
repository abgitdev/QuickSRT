#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$ROOT_DIR/Runtime/runtime-policy.json"
INPUT="$ROOT_DIR/Runtime/requirements.in"
LOCK="$ROOT_DIR/Runtime/requirements.lock"
COMPATIBILITY="$ROOT_DIR/Scripts/runtime_compatibility.py"
BOOTSTRAP_PYTHON="${PYTHON_BIN:-python3}"
WORK_DIR="$(mktemp -d /tmp/quicksrt-runtime-update.XXXXXX)"
WHEELHOUSE="$WORK_DIR/wheels"
BASE_INPUT="$WORK_DIR/requirements.without-mlx-whisper"
CANDIDATE_LOCK="$WORK_DIR/requirements.lock"
CANDIDATE_SBOM="$WORK_DIR/runtime-sbom.cdx.json"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

"$BOOTSTRAP_PYTHON" "$COMPATIBILITY" --policy "$POLICY" --mode bootstrap
read -r PIP_PLATFORM PIP_PYTHON PIP_ABI < <(
  "$BOOTSTRAP_PYTHON" "$COMPATIBILITY" --policy "$POLICY" --print-pip-target
)

mkdir -p "$WHEELHOUSE"
awk '!/^mlx-whisper==/' "$INPUT" > "$BASE_INPUT"
MLX_WHISPER_SPEC="$(awk '/^mlx-whisper==/ { print; exit }' "$INPUT")"
[[ -n "$MLX_WHISPER_SPEC" ]] || { echo "requirements.in must pin mlx-whisper" >&2; exit 1; }

PYTHONNOUSERSITE=1 "$BOOTSTRAP_PYTHON" -m pip download \
  --disable-pip-version-check \
  --only-binary=:all: \
  --platform "$PIP_PLATFORM" \
  --python-version "$PIP_PYTHON" \
  --implementation cp \
  --abi "$PIP_ABI" \
  --dest "$WHEELHOUSE" \
  -r "$BASE_INPUT"

# Upstream declares Torch only for its offline conversion helper. QuickSRT's
# verified production route uses pre-converted MLX weights and omits Torch.
PYTHONNOUSERSITE=1 "$BOOTSTRAP_PYTHON" -m pip download \
  --disable-pip-version-check \
  --no-deps \
  --only-binary=:all: \
  --platform "$PIP_PLATFORM" \
  --python-version "$PIP_PYTHON" \
  --implementation cp \
  --abi "$PIP_ABI" \
  --dest "$WHEELHOUSE" \
  "$MLX_WHISPER_SPEC"

"$BOOTSTRAP_PYTHON" "$ROOT_DIR/Scripts/write_runtime_lock.py" \
  --wheelhouse "$WHEELHOUSE" \
  --output "$CANDIDATE_LOCK"
"$BOOTSTRAP_PYTHON" "$ROOT_DIR/Scripts/generate_runtime_sbom.py" \
  --lock "$CANDIDATE_LOCK" \
  --wheelhouse "$WHEELHOUSE" \
  --output "$CANDIDATE_SBOM"

mv "$CANDIDATE_LOCK" "$LOCK"
mv "$CANDIDATE_SBOM" "$ROOT_DIR/Runtime/runtime-sbom.cdx.json"

echo "Updated $LOCK"
echo "Review Runtime/requirements.in, Runtime/runtime-policy.json, and the lock diff together."
echo "Then run Scripts/setup_runtime.sh, Scripts/audit_runtime.sh, and Scripts/runtime_diagnostics.sh."
