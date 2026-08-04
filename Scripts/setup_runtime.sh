#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$ROOT_DIR/Runtime/runtime-policy.json"
LOCK="$ROOT_DIR/Runtime/requirements.lock"
COMPATIBILITY="$ROOT_DIR/Scripts/runtime_compatibility.py"
PREPARER="$ROOT_DIR/Scripts/prepare_packaged_runtime.py"
WHEEL_INSTALLER="$ROOT_DIR/Scripts/install_locked_wheels.py"
INTEGRITY="$ROOT_DIR/Scripts/support_integrity.py"
DEPENDENCY_CHECK="$ROOT_DIR/Scripts/runtime_dependency_check.py"
SBOM_GENERATOR="$ROOT_DIR/Scripts/generate_runtime_sbom.py"
WRAPPER="$ROOT_DIR/Runtime/python-wrapper.sh"
BOOTSTRAP_PYTHON="${PYTHON_BIN:-python3}"
DESTINATION="$ROOT_DIR/Runtime/Support"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destination) DESTINATION="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

PYTHON_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["python"]["packaged_version"])' "$POLICY")"
PYTHON_SERIES="${PYTHON_VERSION%.*}"
PACKAGE_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["python"]["installer"]["url"])' "$POLICY")"
PACKAGE_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["python"]["installer"]["sha256"])' "$POLICY")"
PACKAGE_TEAM="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["python"]["installer"]["developer_id_team"])' "$POLICY")"
PACKAGE_CERT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["python"]["installer"]["certificate_sha256"])' "$POLICY")"
CACHE_DIR="$ROOT_DIR/_LOCAL_BUILD/python-$PYTHON_VERSION-source"
PACKAGE="$CACHE_DIR/python-$PYTHON_VERSION-macos11.pkg"
WHEELHOUSE="$ROOT_DIR/_LOCAL_BUILD/runtime-wheelhouse-cp${PYTHON_SERIES/./}-arm64"
EXPANDED="$ROOT_DIR/_LOCAL_BUILD/python-$PYTHON_VERSION-expanded.$$"
STAGING="${DESTINATION}.staging"
PREVIOUS="${DESTINATION}.previous"

if [[ -z "$DESTINATION" || "$DESTINATION" == "/" || "$DESTINATION" == "$HOME" ]]; then
  echo "Refusing unsafe runtime destination: $DESTINATION" >&2
  exit 1
fi
if [[ "$STAGING" != "${DESTINATION}.staging" || "$PREVIOUS" != "${DESTINATION}.previous" ]]; then
  exit 1
fi

cleanup() {
  status=$?
  case "$EXPANDED" in "$ROOT_DIR"/_LOCAL_BUILD/python-*-expanded.*) rm -rf "$EXPANDED" ;; esac
  exit "$status"
}
trap cleanup EXIT

if [[ ! -e "$DESTINATION" && -e "$PREVIOUS" ]]; then
  mv "$PREVIOUS" "$DESTINATION"
fi
if [[ -e "$PREVIOUS" ]]; then
  if python3 "$INTEGRITY" verify --root "$DESTINATION" --manifest "$DESTINATION/runtime-manifest.json" >/dev/null 2>&1; then
    rm -rf "$PREVIOUS"
  else
    rm -rf "$DESTINATION"
    mv "$PREVIOUS" "$DESTINATION"
  fi
fi

"$BOOTSTRAP_PYTHON" "$COMPATIBILITY" --policy "$POLICY" --mode bootstrap
read -r PIP_PLATFORM PIP_PYTHON PIP_ABI < <(
  "$BOOTSTRAP_PYTHON" "$COMPATIBILITY" --policy "$POLICY" --print-pip-target
)

mkdir -p "$CACHE_DIR" "$WHEELHOUSE" "$(dirname "$DESTINATION")"
if [[ ! -f "$PACKAGE" ]]; then
  /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 "$PACKAGE_URL" --output "$PACKAGE"
fi
ACTUAL_PACKAGE_SHA="$(shasum -a 256 "$PACKAGE" | awk '{print $1}')"
if [[ "$ACTUAL_PACKAGE_SHA" != "$PACKAGE_SHA" ]]; then
  echo "Python installer SHA-256 mismatch: expected $PACKAGE_SHA, got $ACTUAL_PACKAGE_SHA" >&2
  exit 1
fi
SIGNATURE_OUTPUT="$(pkgutil --check-signature "$PACKAGE")"
COMPACT_SIGNATURE="$(printf '%s' "$SIGNATURE_OUTPUT" | tr -d '[:space:]:' | tr '[:upper:]' '[:lower:]')"
if [[ "$SIGNATURE_OUTPUT" != *"($PACKAGE_TEAM)"* || "$COMPACT_SIGNATURE" != *"$PACKAGE_CERT"* ]]; then
  echo "Python installer signature identity does not match runtime policy." >&2
  exit 1
fi

rm -rf "$EXPANDED" "$STAGING"
pkgutil --expand-full "$PACKAGE" "$EXPANDED"
FRAMEWORK_PAYLOAD="$EXPANDED/Python_Framework.pkg/Payload"
if [[ ! -x "$FRAMEWORK_PAYLOAD/Versions/$PYTHON_SERIES/bin/python3" ]]; then
  echo "Python framework payload is missing its interpreter." >&2
  exit 1
fi

mkdir -p "$STAGING/Python.framework" "$STAGING/site-packages" "$STAGING/venv/bin"
/usr/bin/ditto "$FRAMEWORK_PAYLOAD" "$STAGING/Python.framework"
/usr/bin/ditto "$WRAPPER" "$STAGING/venv/bin/python"
chmod 755 "$STAGING/venv/bin/python"
ln -s python "$STAGING/venv/bin/python3"
ln -s python "$STAGING/venv/bin/python$PYTHON_SERIES"

PYTHONNOUSERSITE=1 "$BOOTSTRAP_PYTHON" -m pip download \
  --disable-pip-version-check \
  --require-hashes \
  --no-deps \
  --only-binary=:all: \
  --platform "$PIP_PLATFORM" \
  --python-version "$PIP_PYTHON" \
  --implementation cp \
  --abi "$PIP_ABI" \
  --dest "$WHEELHOUSE" \
  -r "$LOCK"
python3 "$WHEEL_INSTALLER" \
  --lock "$LOCK" \
  --wheelhouse "$WHEELHOUSE" \
  --target "$STAGING/site-packages"

python3 "$PREPARER" --root "$STAGING"
python3 "$SBOM_GENERATOR" --lock "$LOCK" --wheelhouse "$WHEELHOUSE" --output "$STAGING/runtime-sbom.cdx.json"
python3 "$INTEGRITY" scan --root "$STAGING"
python3 "$INTEGRITY" create --root "$STAGING" --output "$STAGING/runtime-manifest.json"
python3 "$INTEGRITY" verify --root "$STAGING" --manifest "$STAGING/runtime-manifest.json"

if [[ "$(/usr/bin/lipo -archs "$STAGING/Python.framework/Versions/$PYTHON_SERIES/bin/python3")" != *arm64* ]]; then
  echo "Packaged Python does not contain arm64." >&2
  exit 1
fi
"$STAGING/venv/bin/python" -c 'import platform,sys; assert platform.machine() == "arm64"; assert platform.python_version() == sys.argv[1]' "$PYTHON_VERSION"
"$STAGING/venv/bin/python" -m pip --version
"$STAGING/venv/bin/python" "$DEPENDENCY_CHECK"
"$STAGING/venv/bin/python" "$COMPATIBILITY" --policy "$POLICY" --mode runtime
"$STAGING/venv/bin/python" -c 'import mlx, mlx_whisper, numpy; print("MLX runtime imports passed")'

if [[ -e "$PREVIOUS" ]]; then
  echo "Refusing to overwrite runtime recovery directory: $PREVIOUS" >&2
  exit 1
fi
if [[ -e "$DESTINATION" ]]; then
  mv "$DESTINATION" "$PREVIOUS"
fi
mv "$STAGING" "$DESTINATION"

rollback() {
  rm -rf "$DESTINATION"
  if [[ -e "$PREVIOUS" ]]; then mv "$PREVIOUS" "$DESTINATION"; fi
}
if ! python3 "$INTEGRITY" verify --root "$DESTINATION" --manifest "$DESTINATION/runtime-manifest.json" \
  || ! python3 "$INTEGRITY" scan --root "$DESTINATION" \
  || ! "$DESTINATION/venv/bin/python" "$DEPENDENCY_CHECK" \
  || ! "$DESTINATION/venv/bin/python" -c 'import mlx, mlx_whisper, numpy' \
  || ! "$DESTINATION/site-packages/bin/mlx_whisper" --help >/dev/null \
  || ! "$DESTINATION/site-packages/bin/hf" --help >/dev/null; then
  rollback
  echo "Runtime validation failed in its final location; the previous runtime was restored." >&2
  exit 1
fi

rm -rf "$PREVIOUS"
trap - EXIT
rm -rf "$EXPANDED"
echo "Verified relocatable runtime ready: $DESTINATION"
