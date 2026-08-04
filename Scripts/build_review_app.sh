#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT="$REPO_ROOT/Source/QuickSRTProject/QuickSRT.xcodeproj"
SCHEME="QuickSRT"
CONFIGURATION="Release"
LOCAL_BUILD_ROOT="$REPO_ROOT/_LOCAL_BUILD/review"
DERIVED_DATA="$LOCAL_BUILD_ROOT/DerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/QuickSRT.app"
STAGED_APP="$LOCAL_BUILD_ROOT/QuickSRT.app"
DESTINATION="${QUICKSRT_REVIEW_DESTINATION:-${HOME}/Desktop/QuickSRT.app}"
DESTINATION_STAGING="${DESTINATION%.app}.staging.app"
DESTINATION_PREVIOUS="${DESTINATION%.app}.previous.app"
APP_SUPPORT="${QUICKSRT_SUPPORT_DESTINATION:-${HOME}/Library/Application Support/QuickSRT}"
MODELS_ROOT="$APP_SUPPORT/Models"
EXPECTED_IDENTIFIER="local.quicksrt.app"
RELEASE_SETTINGS_VERIFIER="$REPO_ROOT/Scripts/verify_release_build_settings.sh"
RELEASE_SECURITY_VERIFIER="$REPO_ROOT/Scripts/verify_release_security.sh"
SUPPORT_PACKAGER="$REPO_ROOT/Scripts/package_app_support.sh"

case "$LOCAL_BUILD_ROOT" in "$REPO_ROOT"/_LOCAL_BUILD/*) ;; *) exit 1 ;; esac
case "$DESTINATION" in "$HOME"/Desktop/QuickSRT.app|*/QuickSRT.app) ;; *)
  echo "Review destination must be an explicit QuickSRT.app path." >&2; exit 1 ;;
esac
if [[ -z "$APP_SUPPORT" || "$APP_SUPPORT" == "/" || "$APP_SUPPORT" == "$HOME" ]]; then
  echo "Refusing unsafe Application Support path." >&2
  exit 1
fi
if pgrep -x QuickSRT >/dev/null 2>&1; then
  echo "QuickSRT is running. Close it before installing a review build." >&2
  exit 1
fi

read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$2"; }
bundle_identifier() {
  local info="$1/Contents/Info.plist"
  [[ -f "$info" ]] && read_plist CFBundleIdentifier "$info" 2>/dev/null || true
}
validate_app() {
  local app="$1"
  [[ "$(bundle_identifier "$app")" == "$EXPECTED_IDENTIFIER" ]] \
    && [[ -x "$app/Contents/MacOS/QuickSRT" ]] \
    && /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1
}

# Recover a transaction interrupted after the previous app was renamed.
if [[ ! -e "$DESTINATION" && -e "$DESTINATION_PREVIOUS" ]]; then
  if [[ "$(bundle_identifier "$DESTINATION_PREVIOUS")" == "$EXPECTED_IDENTIFIER" ]]; then
    mv "$DESTINATION_PREVIOUS" "$DESTINATION"
  else
    echo "Unrecognized recovery app: $DESTINATION_PREVIOUS" >&2
    exit 1
  fi
fi
if [[ -e "$DESTINATION_PREVIOUS" ]]; then
  if validate_app "$DESTINATION"; then
    rm -rf "$DESTINATION_PREVIOUS"
  else
    rm -rf "$DESTINATION"
    mv "$DESTINATION_PREVIOUS" "$DESTINATION"
  fi
fi
if [[ -e "$DESTINATION_STAGING" ]]; then
  rm -rf "$DESTINATION_STAGING"
fi
if [[ -e "$DESTINATION" && "$(bundle_identifier "$DESTINATION")" != "$EXPECTED_IDENTIFIER" ]]; then
  echo "Destination exists but is not QuickSRT; refusing to overwrite it: $DESTINATION" >&2
  exit 1
fi

rm -rf "$LOCAL_BUILD_ROOT"
mkdir -p "$LOCAL_BUILD_ROOT"

echo "Running QuickSRT tests..."
"$RELEASE_SETTINGS_VERIFIER"
PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 python3 -m unittest discover -s "$REPO_ROOT/Scripts" -p 'test_*.py'
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  ENABLE_TESTABILITY=YES \
  ENABLE_HARDENED_RUNTIME=NO \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES \
  DEPLOYMENT_POSTPROCESSING=NO \
  COPY_PHASE_STRIP=NO \
  STRIP_INSTALLED_PRODUCT=NO \
  DEAD_CODE_STRIPPING=NO \
  test

echo "Building QuickSRT review app..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  ENABLE_CODE_COVERAGE=NO \
  CLANG_COVERAGE_MAPPING=NO \
  build

if [[ ! -x "$BUILT_APP/Contents/MacOS/QuickSRT" ]]; then
  echo "Xcode did not produce a valid QuickSRT.app." >&2
  exit 1
fi
/usr/bin/ditto "$BUILT_APP" "$STAGED_APP"
# Preserve the dSYM in _LOCAL_BUILD, but do not ship local object/source paths
# from the linker's symbol table in the user-facing executable.
/usr/bin/strip -S "$STAGED_APP/Contents/MacOS/QuickSRT"
STAGED_SUPPORT="$STAGED_APP/Contents/Resources/QuickSRTSupport"
"$SUPPORT_PACKAGER" "$STAGED_APP" "$MODELS_ROOT"

# Nested runtime code is already signed. Seal the immutable support directory in
# the app's outer signature without rewriting nested hashes.
/usr/bin/codesign --force --sign - --options runtime --timestamp=none "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
"$RELEASE_SECURITY_VERIFIER" local-review "$STAGED_APP"
python3 "$STAGED_SUPPORT/Scripts/support_integrity.py" verify \
  --root "$STAGED_SUPPORT" --manifest "$STAGED_SUPPORT/support-manifest.json"
python3 "$STAGED_SUPPORT/Scripts/support_integrity.py" scan \
  --root "$STAGED_APP" --root "$MODELS_ROOT"

INFO_PLIST="$STAGED_APP/Contents/Info.plist"
BUNDLE_IDENTIFIER="$(read_plist CFBundleIdentifier "$INFO_PLIST")"
MARKETING_VERSION="$(read_plist CFBundleShortVersionString "$INFO_PLIST")"
BUILD_NUMBER="$(read_plist CFBundleVersion "$INFO_PLIST")"
[[ "$BUNDLE_IDENTIFIER" == "$EXPECTED_IDENTIFIER" ]] || exit 1

mkdir -p "$(dirname "$DESTINATION")"
/usr/bin/ditto "$STAGED_APP" "$DESTINATION_STAGING"
validate_app "$DESTINATION_STAGING" || { echo "Desktop staging app failed validation." >&2; exit 1; }

if [[ -e "$DESTINATION" ]]; then
  mv "$DESTINATION" "$DESTINATION_PREVIOUS"
fi
if ! mv "$DESTINATION_STAGING" "$DESTINATION"; then
  if [[ -e "$DESTINATION_PREVIOUS" ]]; then mv "$DESTINATION_PREVIOUS" "$DESTINATION"; fi
  exit 1
fi
if ! validate_app "$DESTINATION"; then
  rm -rf "$DESTINATION"
  if [[ -e "$DESTINATION_PREVIOUS" ]]; then mv "$DESTINATION_PREVIOUS" "$DESTINATION"; fi
  echo "Installed app failed validation; the previous app was restored." >&2
  exit 1
fi

INSTALLED_SUPPORT="$DESTINATION/Contents/Resources/QuickSRTSupport"
"$RELEASE_SECURITY_VERIFIER" local-review "$DESTINATION"
python3 "$INSTALLED_SUPPORT/Scripts/support_integrity.py" verify \
  --root "$INSTALLED_SUPPORT" --manifest "$INSTALLED_SUPPORT/support-manifest.json"
QUICKSRT_MODELS_ROOT="$MODELS_ROOT" "$INSTALLED_SUPPORT/Scripts/runtime_diagnostics.sh"

rm -rf "$DESTINATION_PREVIOUS"

# Obsolete executable support is deliberately removed only after the signed app
# has succeeded. Models and their user-selected data remain in Application Support.
for legacy in Tools Runtime Scripts; do
  if [[ -e "$APP_SUPPORT/$legacy" ]]; then rm -rf "$APP_SUPPORT/$legacy"; fi
done

CHECKSUM="$(shasum -a 256 "$DESTINATION/Contents/MacOS/QuickSRT" | awk '{print $1}')"
echo "Installed review build: $DESTINATION"
echo "Immutable support: $INSTALLED_SUPPORT"
echo "Persistent models: $MODELS_ROOT"
echo "Bundle identifier: $BUNDLE_IDENTIFIER"
echo "Version: $MARKETING_VERSION"
echo "Build: $BUILD_NUMBER"
echo "Executable SHA-256: $CHECKSUM"
