#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Source/QuickSRTProject/QuickSRT.xcodeproj"
DERIVED_DATA="$ROOT_DIR/DerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/QuickSRT.app"
DEST_APP="$ROOT_DIR/App/QuickSRT.app"

xcodebuild \
  -project "$PROJECT" \
  -scheme QuickSRT \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  build

rm -rf "$DEST_APP"
mkdir -p "$ROOT_DIR/App"
cp -R "$BUILT_APP" "$DEST_APP"

echo "Built app: $DEST_APP"
