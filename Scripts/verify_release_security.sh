#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
app="${2:-}"

if [[ "$mode" != "local-review" && "$mode" != "distribution" ]]; then
  echo "Usage: $0 <local-review|distribution> <QuickSRT.app>" >&2
  exit 2
fi
if [[ ! -d "$app" || ! -x "$app/Contents/MacOS/QuickSRT" ]]; then
  echo "Not a QuickSRT application bundle: $app" >&2
  exit 2
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

signature_info="$(/usr/bin/codesign -d --verbose=4 "$app" 2>&1)"
entitlements="$(/usr/bin/codesign -d --entitlements :- "$app" 2>&1 || true)"
forbidden_entitlements=(
  com.apple.security.get-task-allow
  com.apple.security.cs.allow-jit
  com.apple.security.cs.allow-unsigned-executable-memory
  com.apple.security.cs.allow-dyld-environment-variables
  com.apple.security.cs.disable-library-validation
  com.apple.security.cs.disable-executable-page-protection
)

reject_forbidden_entitlements() {
  local object="$1"
  local object_entitlements="$2"
  local forbidden_entitlement
  for forbidden_entitlement in "${forbidden_entitlements[@]}"; do
    if /usr/bin/grep -Fq "$forbidden_entitlement" <<<"$object_entitlements"; then
      echo "Forbidden Release entitlement in $object: $forbidden_entitlement" >&2
      exit 1
    fi
  done
  if /usr/bin/grep -Fq 'com.apple.security.app-sandbox' <<<"$object_entitlements"; then
    echo "Unexpected App Sandbox entitlement in $object; the current architecture requires an explicit migration." >&2
    exit 1
  fi
}

if ! /usr/bin/grep -Eq 'flags=.*runtime' <<<"$signature_info"; then
  echo "The application signature does not enable Hardened Runtime." >&2
  exit 1
fi

reject_forbidden_entitlements "QuickSRT.app" "$entitlements"

checked_macho=0
while IFS= read -r -d '' candidate; do
  file_description="$(/usr/bin/file -b "$candidate")"
  if [[ "$file_description" != *"Mach-O"* ]]; then
    continue
  fi
  /usr/bin/codesign --verify --strict "$candidate" >/dev/null
  checked_macho=$((checked_macho + 1))

  if [[ "$file_description" == *"executable"* ]]; then
    nested_entitlements="$(/usr/bin/codesign -d --entitlements :- "$candidate" 2>&1 || true)"
    reject_forbidden_entitlements "${candidate#"$app"/}" "$nested_entitlements"
  fi

  if [[ "$mode" == "distribution" ]]; then
    nested_signature="$(/usr/bin/codesign -d --verbose=4 "$candidate" 2>&1)"
    if /usr/bin/grep -Fq 'Signature=adhoc' <<<"$nested_signature" \
      || ! /usr/bin/grep -Fq 'Authority=Developer ID Application:' <<<"$nested_signature"; then
      echo "Nested code lacks Developer ID Application signing: ${candidate#"$app"/}" >&2
      exit 1
    fi
    if ! /usr/bin/grep -Eq '^Timestamp=' <<<"$nested_signature"; then
      echo "Nested code lacks a secure timestamp: ${candidate#"$app"/}" >&2
      exit 1
    fi
    if [[ "$file_description" == *"executable"* ]] \
      && ! /usr/bin/grep -Eq 'flags=.*runtime' <<<"$nested_signature"; then
      echo "Nested executable lacks Hardened Runtime: ${candidate#"$app"/}" >&2
      exit 1
    fi
  fi
done < <(find "$app/Contents" -type f -print0)

if [[ "$checked_macho" -eq 0 ]]; then
  echo "No Mach-O code found in application bundle." >&2
  exit 1
fi

if [[ "$mode" == "local-review" ]]; then
  if ! /usr/bin/grep -Fq 'Signature=adhoc' <<<"$signature_info"; then
    echo "Local review mode requires an explicit ad hoc signature." >&2
    exit 1
  fi
  if /usr/sbin/spctl --assess --type execute "$app" >/dev/null 2>&1; then
    gatekeeper_status="accepted by this Mac's local policy"
  else
    gatekeeper_status="rejected as expected without Developer ID and notarization"
  fi
  echo "Verified local review security: Hardened Runtime, no forbidden entitlements, $checked_macho signed Mach-O files; Gatekeeper $gatekeeper_status."
  exit 0
fi

if /usr/bin/grep -Fq 'Signature=adhoc' <<<"$signature_info" \
  || ! /usr/bin/grep -Fq 'Authority=Developer ID Application:' <<<"$signature_info" \
  || /usr/bin/grep -Fq 'TeamIdentifier=not set' <<<"$signature_info"; then
  echo "Distribution is blocked: a Developer ID Application signature is required." >&2
  exit 1
fi
if ! /usr/bin/grep -Eq '^Timestamp=' <<<"$signature_info"; then
  echo "Distribution is blocked: a secure Apple timestamp is required." >&2
  exit 1
fi

/usr/bin/xcrun stapler validate "$app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$app"
echo "Verified Developer ID distribution security for $checked_macho Mach-O files."
