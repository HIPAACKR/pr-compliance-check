#!/usr/bin/env bash
# Package the checked-out HEAD for the agentic sweep.
#
# Run from the repository root. Env:
#   SOURCE_EXCLUDES  extra tar exclude globs, comma- or newline-separated
#   MAX_FILE_BYTES   per-file size cap (default 2 MB); lockfiles are exempt
#   OUT_DIR          state directory (default /tmp); writes source.tar.gz
#
# The agentic engine reads the actual code; upload the checked-out HEAD so it
# can. FAST is deprecated: without this (and no configured codebase reuse) the
# server returns BLOCKED, not a pass.
#
# The member list comes from git, not from the directory. tar has no concept
# of .gitignore, so tarring the workspace archives whatever an earlier
# workflow step happened to leave on disk (build output, caches, fixtures).
# Tracked-only makes that whole class of bloat unreachable instead of relying
# on an exclude list to enumerate it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

if cc_decided; then
  echo "Outcome already recorded ($(head -n1 "$OUT_DIR/outcome.txt")); not packaging the source."
  exit 0
fi

# Members the scanner cannot read as source. Two independent rules, because
# neither catches the other's case: compiled/packaged binaries by extension (a
# vendored apktool.jar is 20 MB and gzip can't touch an already-compressed
# archive), and a per-file size cap for oversized text (Figma exports raster
# JPEGs base64-embedded inside .svg wrappers, which routinely weigh 20 MB+ each
# and are not binary by extension). .svg is deliberately NOT listed: an SVG
# can carry <script>, so small ones stay in scope and only oversized ones fall
# to the size cap below.
BIN_EXT='jar|war|ear|aar|apk|aab|ipa|dex|class|zip|7z|rar|gz|tgz|bz2|xz|zst|iso|dmg|exe|msi|dll|so|dylib|rlib|pyc|pyo|wasm|pdf|psd|ai|sketch|fig|eps|mp4|mov|avi|mkv|webm|mp3|wav|flac|ogg|ttf|otf|woff|woff2|eot|db|sqlite|sqlite3|mdb|dump|bin|pack|idx|node|whl|egg|jasper|png|jpg|jpeg|gif|webp|bmp|tif|tiff|ico|avif|heic'
MAX_FILE_BYTES="$(cc_int "${MAX_FILE_BYTES:-}" 2097152)"
ARCHIVE="$OUT_DIR/source.tar.gz"
# The server's archive cap (100 MB). CC_ARCHIVE_CAP_BYTES exists for tests.
CAP="$(cc_int "${CC_ARCHIVE_CAP_BYTES:-}" 104857600)"
MEMBERS="$OUT_DIR/source_members.z"
DROPPED_LIST="$OUT_DIR/source_dropped.txt"

# Files that may hold secrets never leave the runner, whatever the inputs say
# (W13/F13). Matched on the file name, anywhere in the tree, ignoring case.
is_secret_file() {
  local base
  base=$(printf '%s' "${1##*/}" | tr '[:upper:]' '[:lower:]')
  case "$base" in
    .env | .env.* | *.pem | *.key | *.p12 | *.pfx | *.jks | *.keystore) return 0 ;;
  esac
  return 1
}

# Lockfiles are large but are what the dependency (SCA) check reads, so the
# per-file size cap does not apply to them (SC-01).
is_lockfile() {
  case "${1##*/}" in
    package-lock.json | yarn.lock | pnpm-lock.yaml | Gemfile.lock | composer.lock | poetry.lock | Pipfile.lock | Cargo.lock | go.sum) return 0 ;;
  esac
  return 1
}

# GNU stat on the runner; the BSD form keeps this runnable for local checks.
if stat -c '%s' . >/dev/null 2>&1; then
  _size() { stat -c '%s' "$1"; }
else
  _size() { stat -f '%z' "$1"; }
fi

: > "$MEMBERS"
: > "$DROPPED_LIST"
KEPT=0
DROPPED=0
DROPPED_BYTES=0
SECRETS=0
while IFS= read -r -d '' f; do
  # Tracked-but-absent (submodule gitlinks, sparse checkouts) - skip quietly.
  if [ ! -f "$f" ] || [ -L "$f" ]; then
    continue
  fi
  EXT="${f##*.}"
  REASON=""
  FSZ=""
  if is_secret_file "$f"; then
    REASON="may hold secrets; never uploaded"
    SECRETS=$((SECRETS + 1))
  elif printf '%s' "$EXT" | grep -qiE "^(${BIN_EXT})$"; then
    REASON="binary type .${EXT}"
  elif ! is_lockfile "$f"; then
    FSZ=$(_size "$f" 2>/dev/null || echo 0)
    if [ "$FSZ" -gt "$MAX_FILE_BYTES" ]; then
      REASON="${FSZ} bytes > per-file cap ${MAX_FILE_BYTES}"
    fi
  fi
  if [ -n "$REASON" ]; then
    [ -z "$FSZ" ] && FSZ=$(_size "$f" 2>/dev/null || echo 0)
    printf '%12s  %s  (%s)\n' "$FSZ" "$f" "$REASON" >> "$DROPPED_LIST"
    DROPPED=$((DROPPED + 1))
    DROPPED_BYTES=$((DROPPED_BYTES + FSZ))
    continue
  fi
  # Keep the ./ prefix so member names stay identical to previous releases.
  printf './%s\0' "$f" >> "$MEMBERS"
  KEPT=$((KEPT + 1))
done < <(git ls-files -z)

# Consumer-supplied extra excludes, one glob per line or comma-separated.
EXTRA_ARGS=()
if [ -n "${SOURCE_EXCLUDES:-}" ]; then
  # `|| [ -n "$pat" ]` so the final pattern survives the missing trailing
  # newline; trim only surrounding blanks, since a glob may contain spaces.
  while IFS= read -r pat || [ -n "$pat" ]; do
    pat="${pat#"${pat%%[![:space:]]*}"}"
    pat="${pat%"${pat##*[![:space:]]}"}"
    if [ -n "$pat" ]; then
      EXTRA_ARGS+=(--exclude="$pat")
      echo "Extra exclude: $pat"
    fi
  done < <(printf '%s' "$SOURCE_EXCLUDES" | tr ',' '\n')
fi

if ! tar czf "$ARCHIVE" \
  --exclude='.git' --exclude='node_modules' --exclude='vendor' \
  --exclude='tmp' --exclude='log' --exclude='.bundle' --exclude='*.log' \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
  --null -T "$MEMBERS"; then
  cc_give_up action_error "tar could not build the source archive. See the job log."
  exit 0
fi

SZ=$(wc -c < "$ARCHIVE" | tr -d ' ')
echo "Packaged ${KEPT} tracked files; left out ${DROPPED} (${DROPPED_BYTES} bytes)."
if [ "$DROPPED" -gt 0 ]; then
  echo "Left out of the archive (first 200):"
  head -n 200 "$DROPPED_LIST" | sed 's/^/  /'
fi
[ "$SECRETS" -gt 0 ] && echo "${SECRETS} file(s) that may hold secrets (.env, keys, keystores) were left out by default."
echo "source.tar.gz: ${SZ} bytes"

if [ "$SZ" -gt "$CAP" ]; then
  # Show what to fix rather than just refusing. Without this the consumer is
  # told to "add excludes" with no idea which files are the problem.
  echo "Largest members still in the archive:"
  tr '\0' '\n' < "$MEMBERS" | sed 's|^\./||' | while IFS= read -r f; do
    [ -f "$f" ] && printf '%12s  %s\n' "$(_size "$f")" "$f"
  done | sort -rn | head -25
  cc_give_up source_too_large "The source archive is ${SZ} bytes, over the ${CAP}-byte (100 MB) server cap. Set source-excludes to drop large assets, or lower max-file-bytes (now ${MAX_FILE_BYTES})."
  exit 0
fi

if [ "$SZ" -gt $((CAP / 5 * 4)) ]; then
  cc_warn "Source archive is ${SZ} bytes, over 80% of the 100 MB cap. Consider trimming large assets before it starts failing."
fi
exit 0
