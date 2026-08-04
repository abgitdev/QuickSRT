#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
project="$repository_root/Source/QuickSRTProject/QuickSRT.xcodeproj"

settings="$(
  xcodebuild \
    -project "$project" \
    -target QuickSRT \
    -configuration Release \
    -sdk macosx \
    -showBuildSettings 2>/dev/null
)"

setting_value() {
  local key="$1"
  awk -F ' = ' -v requested="$key" '$1 ~ "^[[:space:]]*" requested "$" { print $2; exit }' <<<"$settings"
}

require_setting() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(setting_value "$key")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Unsafe Release setting $key: expected $expected, got ${actual:-<missing>}." >&2
    exit 1
  fi
}

require_setting ENABLE_HARDENED_RUNTIME YES
require_setting CODE_SIGN_INJECT_BASE_ENTITLEMENTS NO
require_setting ENABLE_APP_SANDBOX NO
require_setting ARCHS arm64
require_setting ONLY_ACTIVE_ARCH NO
require_setting MACOSX_DEPLOYMENT_TARGET 15.0
require_setting ENABLE_TESTABILITY NO
require_setting ENABLE_CODE_COVERAGE NO
require_setting CLANG_COVERAGE_MAPPING NO
require_setting GCC_GENERATE_TEST_COVERAGE_FILES NO
require_setting GCC_INSTRUMENT_PROGRAM_FLOW_ARCS NO
require_setting GENERATE_PROFILING_CODE NO
require_setting DEAD_CODE_STRIPPING YES
require_setting COPY_PHASE_STRIP YES
require_setting DEPLOYMENT_POSTPROCESSING YES
require_setting STRIP_INSTALLED_PRODUCT YES
require_setting STRIP_STYLE all
require_setting DEBUG_INFORMATION_FORMAT dwarf-with-dsym
require_setting SWIFT_OPTIMIZATION_LEVEL -O
require_setting SWIFT_SERIALIZE_DEBUGGING_OPTIONS NO
require_setting SKIP_INSTALL NO

echo "Verified production Release settings: arm64-only macOS 15, coverage/profiling disabled, optimized dead-strip build, external dSYM, Hardened Runtime policy enforced."
