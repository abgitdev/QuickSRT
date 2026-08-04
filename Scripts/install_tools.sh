#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/FFmpeg/manifest.json"
VERIFIER="$ROOT_DIR/Scripts/verify_ffmpeg_tools.py"
TOOLS_DIR="$ROOT_DIR/Tools"
STAGING="$ROOT_DIR/.Tools.staging"
PREVIOUS="$ROOT_DIR/.Tools.previous"
SOURCE_DIR="${1:-$ROOT_DIR/_LOCAL_BUILD/ffmpeg-8.1.2/artifacts}"

for path in "$STAGING" "$PREVIOUS"; do
  case "$path" in
    "$ROOT_DIR"/.Tools.*) ;;
    *) echo "Refusing unsafe tools transaction path: $path" >&2; exit 1 ;;
  esac
done

if [[ ! -d "$TOOLS_DIR" && -d "$PREVIOUS" ]]; then
  mv "$PREVIOUS" "$TOOLS_DIR"
fi

if [[ -d "$PREVIOUS" ]]; then
  if python3 "$VERIFIER" --tools "$TOOLS_DIR" --manifest "$MANIFEST" >/dev/null 2>&1; then
    rm -rf "$PREVIOUS"
  else
    rm -rf "$TOOLS_DIR"
    mv "$PREVIOUS" "$TOOLS_DIR"
  fi
fi

python3 "$VERIFIER" --tools "$SOURCE_DIR" --manifest "$MANIFEST"
rm -rf "$STAGING"
mkdir -p "$STAGING"
touch "$STAGING/.gitkeep"
/usr/bin/ditto "$SOURCE_DIR/ffmpeg" "$STAGING/ffmpeg"
/usr/bin/ditto "$SOURCE_DIR/ffprobe" "$STAGING/ffprobe"
chmod 755 "$STAGING/ffmpeg" "$STAGING/ffprobe"
python3 "$VERIFIER" --tools "$STAGING" --manifest "$MANIFEST"

if [[ -e "$PREVIOUS" ]]; then
  echo "Refusing to overwrite tools recovery directory: $PREVIOUS" >&2
  exit 1
fi
if [[ -e "$TOOLS_DIR" ]]; then
  mv "$TOOLS_DIR" "$PREVIOUS"
fi
mv "$STAGING" "$TOOLS_DIR"

if ! python3 "$VERIFIER" --tools "$TOOLS_DIR" --manifest "$MANIFEST"; then
  rm -rf "$TOOLS_DIR"
  if [[ -e "$PREVIOUS" ]]; then mv "$PREVIOUS" "$TOOLS_DIR"; fi
  echo "Tool installation failed; the previous Tools directory was restored." >&2
  exit 1
fi

rm -rf "$PREVIOUS"
echo "Installed verified native FFmpeg tools: $TOOLS_DIR"
