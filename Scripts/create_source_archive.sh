#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT_FILE="$REPO_ROOT/Source/QuickSRTProject/QuickSRT.xcodeproj/project.pbxproj"

if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all)" ]]; then
  echo "Refusing to create a release archive from a dirty Git tree." >&2
  exit 1
fi

VERSION="$(
  sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' "$PROJECT_FILE" | sort -u
)"

if [[ -z "$VERSION" || "$VERSION" == *$'\n'* ]]; then
  echo "Could not resolve one canonical MARKETING_VERSION." >&2
  exit 1
fi

PREFIX="QuickSRT-$VERSION/"
DEFAULT_OUTPUT="$REPO_ROOT/_LOCAL_BUILD/release/QuickSRT-$VERSION-source.zip"
OUTPUT="${1:-$DEFAULT_OUTPUT}"

mkdir -p "$(dirname "$OUTPUT")"
if [[ -e "$OUTPUT" ]]; then
  echo "Refusing to overwrite an existing archive: $OUTPUT" >&2
  exit 1
fi

git -C "$REPO_ROOT" archive \
  --format=zip \
  --prefix="$PREFIX" \
  --output="$OUTPUT" \
  HEAD

ARCHIVE_LIST="$(unzip -Z1 "$OUTPUT")"
FORBIDDEN_PATTERN='(^|/)(Models|DerivedData|_LOCAL_BUILD|_PRIVATE|_PRIVATE_CHATS|_PROJECT_AUDIT|_PROJECT_RESEARCH|\.codex|\.codex-local|\.Tools\.staging|\.Tools\.previous|Temp|tmp|cache|Cache|Output|DiagnosticReports|Screenshots|screenshots|_SCREENSHOTS)(/|$)|(^|/)Runtime/(venv|Support)(/|$)|(^|/)Tools/(ffmpeg|ffprobe)$|\.app(/|$)|\.dSYM(/|$)|\.xcarchive(/|$)|\.xcresult(/|$)|\.trace(/|$)|(^|/)(PROJECT_MEMORY([^/]*)?|AGENTS([^/]*)?|SESSION_NOTES\.local)\.md$|(^|/)КАК_ПУБЛИКОВАТЬ_ПРОЕКТЫ_НА_GITHUB\.md$|(^|/)xcuserdata(/|$)|(^|/)\.env[^/]*$|\.(pem|key|p8|p12|pfx|cer|crt|certSigningRequest|developerprofile|mobileprovision|provisionprofile)$|\.(zip|tar|gz|bz2|xz|zst|7z|rar|dmg|pkg|iso)$|\.(mp4|mov|mkv|avi|m4v|webm|mpeg|mpg|wmv|flv|3gp|mts|m2ts|ogv|mxf|mp3|m4a|aif|wav|aiff|aac|caf|flac|ogg|opus|wma|ape|alac|srt|vtt|ass|ssa|sub|sbv|ttml|dfxp|smi|sami|lrc)$|(^|/)(Screenshot |Screen Shot |Снимок экрана |CleanShot )|\.xcuserstate$|\.DS_Store$|\.pyc$|\.log$|\.(crash|ips|diag|hang|spin|spindump|profraw|profdata|gcda|gcno)$'

if grep -Eq "$FORBIDDEN_PATTERN" <<<"$ARCHIVE_LIST"; then
  echo "Forbidden local or generated content was found in the source archive:" >&2
  grep -E "$FORBIDDEN_PATTERN" <<<"$ARCHIVE_LIST" >&2
  rm -f "$OUTPUT"
  exit 1
fi

if ! python3 "$REPO_ROOT/Scripts/source_archive_policy.py" "$OUTPUT"; then
  /bin/rm -f -- "$OUTPUT"
  exit 1
fi

echo "Created source archive from commit $(git -C "$REPO_ROOT" rev-parse --short=12 HEAD): $OUTPUT"
