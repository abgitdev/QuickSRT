#!/usr/bin/env bash
set -euo pipefail

app="${1:-}"
if [[ ! -d "$app" || ! -x "$app/Contents/MacOS/QuickSRT" ]]; then
  echo "Usage: $0 <QuickSRT.app>" >&2
  exit 2
fi

base_tmp="${TMPDIR:-/tmp}"
sandbox_root="$(mktemp -d "${base_tmp%/}/QuickSRT-clean-first-launch.XXXXXX")"
isolated_home="$sandbox_root/home"
isolated_tmp="$sandbox_root/tmp"
log_file="$sandbox_root/launch.log"
pid=""
mkdir -p "$isolated_home" "$isolated_tmp"

cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  case "$sandbox_root" in
    "${base_tmp%/}"/QuickSRT-clean-first-launch.*) rm -rf -- "$sandbox_root" ;;
    *) echo "Refusing to remove unexpected sandbox path: $sandbox_root" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM

if [[ -e "$isolated_home/Library/Application Support/QuickSRT" ]]; then
  echo "Clean-launch sandbox unexpectedly contains QuickSRT data." >&2
  exit 1
fi

HOME="$isolated_home" \
CFFIXED_USER_HOME="$isolated_home" \
TMPDIR="$isolated_tmp/" \
  "$app/Contents/MacOS/QuickSRT" \
    -ApplePersistenceIgnoreState YES \
    -QuickSRT.appLanguage en \
    >"$log_file" 2>&1 &
pid=$!

for _ in {1..40}; do
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    echo "QuickSRT exited during clean first-launch smoke." >&2
    sed -n '1,80p' "$log_file" >&2
    exit 1
  fi
  sleep 0.1
done

models_root="$isolated_home/Library/Application Support/QuickSRT/Models"
if [[ -d "$models_root" ]] && find "$models_root" -type f -print -quit | grep -q .; then
  echo "QuickSRT unexpectedly created model files during first launch." >&2
  exit 1
fi

kill -TERM "$pid"
for _ in {1..100}; do
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    pid=""
    echo "Verified clean first launch without a model or pre-existing QuickSRT caches."
    exit 0
  fi
  sleep 0.1
done

echo "QuickSRT did not terminate within 10 seconds after the clean-launch smoke." >&2
exit 1
