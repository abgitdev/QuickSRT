#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/FFmpeg/manifest.json"
FLAGS_FILE="$ROOT_DIR/FFmpeg/configure.flags"
VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upstream_version"])' "$MANIFEST")"
SOURCE_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"]["url"])' "$MANIFEST")"
SOURCE_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"]["sha256"])' "$MANIFEST")"
CACHE_DIR="$ROOT_DIR/_LOCAL_BUILD/ffmpeg-$VERSION-source"
ARCHIVE="$CACHE_DIR/ffmpeg-$VERSION.tar.xz"
WORK_ROOT="/private/tmp/QuickSRT-FFmpeg-$VERSION"
SOURCE_DIR="$WORK_ROOT/source"
BUILD_DIR="$WORK_ROOT/build"
ARTIFACTS="$ROOT_DIR/_LOCAL_BUILD/ffmpeg-$VERSION/artifacts"

case "$WORK_ROOT" in /private/tmp/QuickSRT-FFmpeg-*) ;; *) exit 1 ;; esac
case "$ARTIFACTS" in "$ROOT_DIR"/_LOCAL_BUILD/*) ;; *) exit 1 ;; esac

cleanup() { rm -rf "$WORK_ROOT"; }
trap cleanup EXIT
rm -rf "$WORK_ROOT" "$ARTIFACTS"
mkdir -p "$CACHE_DIR" "$SOURCE_DIR" "$BUILD_DIR" "$ARTIFACTS"

if [[ ! -f "$ARCHIVE" ]]; then
  /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 "$SOURCE_URL" --output "$ARCHIVE"
fi
ACTUAL_SOURCE_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL_SOURCE_SHA" != "$SOURCE_SHA" ]]; then
  echo "FFmpeg source SHA-256 mismatch: expected $SOURCE_SHA, got $ACTUAL_SOURCE_SHA" >&2
  exit 1
fi

/usr/bin/tar -xJf "$ARCHIVE" --strip-components=1 -C "$SOURCE_DIR"
CONFIGURE_FLAGS=()
while IFS= read -r flag; do
  [[ -n "$flag" ]] && CONFIGURE_FLAGS+=("$flag")
done < "$FLAGS_FILE"
(
  cd "$BUILD_DIR"
  "$SOURCE_DIR/configure" "${CONFIGURE_FLAGS[@]}"
  make -j"$(sysctl -n hw.ncpu)" ffmpeg ffprobe
)

for tool in ffmpeg ffprobe; do
  /usr/bin/ditto "$BUILD_DIR/$tool" "$ARTIFACTS/$tool"
  chmod 755 "$ARTIFACTS/$tool"
  /usr/bin/codesign --force --sign - --timestamp=none "$ARTIFACTS/$tool"
done

python3 "$ROOT_DIR/Scripts/verify_ffmpeg_tools.py" --tools "$ARTIFACTS" --manifest "$MANIFEST"
"$ROOT_DIR/Scripts/install_tools.sh" "$ARTIFACTS"
