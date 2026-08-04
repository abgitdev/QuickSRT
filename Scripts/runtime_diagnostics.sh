#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$ROOT_DIR/Runtime/runtime-policy.json"
LOCK="$ROOT_DIR/Runtime/requirements.lock"
PYTHON="$ROOT_DIR/Runtime/Support/venv/bin/python"
RUNTIME="$ROOT_DIR/Runtime/Support"
FFMPEG_MANIFEST="$ROOT_DIR/FFmpeg/manifest.json"
INTEGRITY="$ROOT_DIR/Scripts/support_integrity.py"
MODELS_ROOT="${QUICKSRT_MODELS_ROOT:-${HOME}/Library/Application Support/QuickSRT/Models}"

echo "QuickSRT runtime diagnostics"
echo "Support root: $ROOT_DIR"
echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "Kernel architecture: $(uname -m)"
echo "Lock SHA-256: $(shasum -a 256 "$LOCK" | awk '{print $1}')"

[[ "$(uname -m)" == "arm64" ]] || { echo "QuickSRT requires native Apple Silicon." >&2; exit 1; }
python3 "$ROOT_DIR/Scripts/verify_ffmpeg_tools.py" \
  --tools "$ROOT_DIR/Tools" \
  --manifest "$FFMPEG_MANIFEST"

if [[ ! -x "$PYTHON" ]]; then
  echo "Runtime Python: missing ($PYTHON)" >&2
  exit 1
fi

python3 "$INTEGRITY" verify --root "$RUNTIME" --manifest "$RUNTIME/runtime-manifest.json"
python3 "$INTEGRITY" scan \
  --root "$RUNTIME" \
  --root "$ROOT_DIR/Tools" \
  --root "$ROOT_DIR/Scripts" \
  --root "$MODELS_ROOT"
"$PYTHON" -c 'import platform; assert platform.machine() == "arm64", platform.machine()'
"$PYTHON" "$ROOT_DIR/Scripts/runtime_compatibility.py" --policy "$POLICY" --mode runtime
"$PYTHON" -m pip --version
"$PYTHON" "$ROOT_DIR/Scripts/runtime_dependency_check.py"
"$RUNTIME/site-packages/bin/mlx_whisper" --help >/dev/null
"$RUNTIME/site-packages/bin/hf" --help >/dev/null

"$ROOT_DIR/Tools/ffmpeg" -version | sed -n '1p'
"$ROOT_DIR/Tools/ffprobe" -version | sed -n '1p'
echo "Runtime diagnostics: OK"
