#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <QuickSRT.app> <managed-models-root>" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
APP="$1"
MODELS_ROOT="$2"
SUPPORT="$APP/Contents/Resources/QuickSRTSupport"

if [[ ! -d "$APP" || ! -x "$APP/Contents/MacOS/QuickSRT" ]]; then
  echo "Not a built QuickSRT application: $APP" >&2
  exit 2
fi
if [[ -z "$MODELS_ROOT" || "$MODELS_ROOT" != /* || "$MODELS_ROOT" == "/" || "$MODELS_ROOT" == "$HOME" ]]; then
  echo "Managed-models root must be an explicit safe absolute path." >&2
  exit 2
fi
if [[ -e "$SUPPORT" ]]; then
  echo "Application support is already present; refusing to merge mutable state: $SUPPORT" >&2
  exit 1
fi

mkdir -p "$SUPPORT/Tools" "$SUPPORT/Runtime" "$SUPPORT/Scripts" \
  "$SUPPORT/FFmpeg" "$SUPPORT/Licenses" "$MODELS_ROOT"

python3 "$REPO_ROOT/Scripts/verify_ffmpeg_tools.py" \
  --tools "$REPO_ROOT/Tools" --manifest "$REPO_ROOT/FFmpeg/manifest.json"
/usr/bin/ditto "$REPO_ROOT/Tools/ffmpeg" "$SUPPORT/Tools/ffmpeg"
/usr/bin/ditto "$REPO_ROOT/Tools/ffprobe" "$SUPPORT/Tools/ffprobe"

for file in manifest.json configure.flags README.md COPYING.LGPLv2.1; do
  /usr/bin/ditto "$REPO_ROOT/FFmpeg/$file" "$SUPPORT/FFmpeg/$file"
done
for file in requirements.lock runtime-policy.json model-policy.json runtime-sbom.cdx.json \
  runtime-vex.json ROUTE_ANALYSIS.md PYTHON_RUNTIME.md; do
  /usr/bin/ditto "$REPO_ROOT/Runtime/$file" "$SUPPORT/Runtime/$file"
done
for file in mlx_transcribe_srt.py download_mlx_whisper_model.py runtime_compatibility.py \
  runtime_dependency_check.py model_integrity.py runtime_diagnostics.sh support_integrity.py \
  privacy_markers.py verify_ffmpeg_tools.py; do
  /usr/bin/ditto "$REPO_ROOT/Scripts/$file" "$SUPPORT/Scripts/$file"
done
for pair in "LICENSE:PROJECT_LICENSE" "THIRD_PARTY_NOTICES:THIRD_PARTY_NOTICES" \
  "PYTHON_DEPENDENCY_LICENSES.md:PYTHON_DEPENDENCY_LICENSES.md"; do
  source_name="${pair%%:*}"
  destination_name="${pair##*:}"
  /usr/bin/ditto "$REPO_ROOT/$source_name" "$SUPPORT/Licenses/$destination_name"
done
chmod 755 "$SUPPORT/Tools/ffmpeg" "$SUPPORT/Tools/ffprobe" \
  "$SUPPORT/Scripts/runtime_diagnostics.sh"

"$REPO_ROOT/Scripts/setup_runtime.sh" --destination "$SUPPORT/Runtime/Support"
python3 "$SUPPORT/Scripts/verify_ffmpeg_tools.py" \
  --tools "$SUPPORT/Tools" --manifest "$SUPPORT/FFmpeg/manifest.json"
python3 "$SUPPORT/Scripts/support_integrity.py" scan \
  --root "$APP" --root "$MODELS_ROOT"
python3 "$SUPPORT/Scripts/support_integrity.py" create \
  --root "$SUPPORT" --output "$SUPPORT/support-manifest.json"
python3 "$SUPPORT/Scripts/support_integrity.py" verify \
  --root "$SUPPORT" --manifest "$SUPPORT/support-manifest.json"
QUICKSRT_MODELS_ROOT="$MODELS_ROOT" "$SUPPORT/Scripts/runtime_diagnostics.sh"

echo "Packaged immutable QuickSRT support: $SUPPORT"
