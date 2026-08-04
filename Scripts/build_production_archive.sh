#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$REPO_ROOT/Source/QuickSRTProject/QuickSRT.xcodeproj"
FINAL_ROOT="$REPO_ROOT/_LOCAL_BUILD/production-archive"
STAGING_ROOT="$REPO_ROOT/_LOCAL_BUILD/production-archive.staging"
PREVIOUS_ROOT="$REPO_ROOT/_LOCAL_BUILD/production-archive.previous"
ARCHIVE_NAME="QuickSRT.xcarchive"
STAGING_ARCHIVE="$STAGING_ROOT/$ARCHIVE_NAME"
FINAL_ARCHIVE="$FINAL_ROOT/$ARCHIVE_NAME"
DERIVED_DATA="$STAGING_ROOT/DerivedData"
MODELS_ROOT="$STAGING_ROOT/ManagedModels"
SETTINGS_VERIFIER="$REPO_ROOT/Scripts/verify_release_build_settings.sh"
SECURITY_VERIFIER="$REPO_ROOT/Scripts/verify_release_security.sh"
ARCHIVE_VERIFIER="$REPO_ROOT/Scripts/verify_production_archive.py"
SUPPORT_PACKAGER="$REPO_ROOT/Scripts/package_app_support.sh"

case "$FINAL_ROOT" in "$REPO_ROOT"/_LOCAL_BUILD/production-archive) ;; *) exit 1 ;; esac
case "$STAGING_ROOT" in "$REPO_ROOT"/_LOCAL_BUILD/production-archive.staging) ;; *) exit 1 ;; esac
case "$PREVIOUS_ROOT" in "$REPO_ROOT"/_LOCAL_BUILD/production-archive.previous) ;; *) exit 1 ;; esac

if [[ ! -e "$FINAL_ROOT" && -e "$PREVIOUS_ROOT" ]]; then
  mv "$PREVIOUS_ROOT" "$FINAL_ROOT"
fi
if [[ -e "$PREVIOUS_ROOT" ]]; then
  if python3 "$ARCHIVE_VERIFIER" "$FINAL_ARCHIVE" >/dev/null 2>&1; then
    rm -rf "$PREVIOUS_ROOT"
  else
    rm -rf "$FINAL_ROOT"
    mv "$PREVIOUS_ROOT" "$FINAL_ROOT"
  fi
fi
if [[ -e "$STAGING_ROOT" ]]; then
  rm -rf "$STAGING_ROOT"
fi
mkdir -p "$STAGING_ROOT"

cleanup() {
  status=$?
  if [[ "$status" -ne 0 && -e "$STAGING_ROOT" ]]; then
    rm -rf "$STAGING_ROOT"
  fi
  exit "$status"
}
trap cleanup EXIT

"$SETTINGS_VERIFIER"

xcodebuild \
  -project "$PROJECT" \
  -scheme QuickSRT \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$STAGING_ARCHIVE" \
  archive

ARCHIVED_APP="$STAGING_ARCHIVE/Products/Applications/QuickSRT.app"
if [[ ! -x "$ARCHIVED_APP/Contents/MacOS/QuickSRT" ]]; then
  echo "Xcode did not create the expected archived QuickSRT application." >&2
  exit 1
fi

"$SUPPORT_PACKAGER" "$ARCHIVED_APP" "$MODELS_ROOT"
SUPPORT="$ARCHIVED_APP/Contents/Resources/QuickSRTSupport"

# Xcode creates the stripped main executable and matching external dSYM before
# support is embedded. Reseal the complete local archive without touching the
# already-signed nested runtime graph.
/usr/bin/codesign --force --sign - --options runtime --timestamp=none "$ARCHIVED_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$ARCHIVED_APP"
"$SECURITY_VERIFIER" local-review "$ARCHIVED_APP"
python3 "$SUPPORT/Scripts/support_integrity.py" verify \
  --root "$SUPPORT" --manifest "$SUPPORT/support-manifest.json"
QUICKSRT_MODELS_ROOT="$MODELS_ROOT" "$SUPPORT/Scripts/runtime_diagnostics.sh"
python3 "$ARCHIVE_VERIFIER" "$STAGING_ARCHIVE"
rmdir "$MODELS_ROOT"

if [[ -e "$FINAL_ROOT" ]]; then
  mv "$FINAL_ROOT" "$PREVIOUS_ROOT"
fi
if ! mv "$STAGING_ROOT" "$FINAL_ROOT"; then
  if [[ -e "$PREVIOUS_ROOT" ]]; then mv "$PREVIOUS_ROOT" "$FINAL_ROOT"; fi
  exit 1
fi

python3 "$ARCHIVE_VERIFIER" "$FINAL_ARCHIVE"
if [[ -e "$PREVIOUS_ROOT" ]]; then
  rm -rf "$PREVIOUS_ROOT"
fi

trap - EXIT
INFO_PLIST="$FINAL_ARCHIVE/Products/Applications/QuickSRT.app/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
DSYM="$FINAL_ARCHIVE/dSYMs/QuickSRT.app.dSYM"
echo "Production archive ready: $FINAL_ARCHIVE"
echo "Version: $VERSION"
echo "Build: $BUILD"
echo "External dSYM: $DSYM"
echo "This local ad hoc archive is not an authorized public binary distribution."
