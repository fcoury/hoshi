#!/usr/bin/env bash
set -euo pipefail

REAL_LIBTOOL="${HOSHI_REAL_LIBTOOL:-$(xcrun --find libtool)}"

if [[ "${1:-}" != "-static" ]]; then
  exec "$REAL_LIBTOOL" "$@"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hoshi-ghostty-libtool.XXXXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

arguments=()
archive_number=0

for argument in "$@"; do
  if [[ "$argument" != *.a || ! -f "$argument" ]]; then
    arguments+=("$argument")
    continue
  fi

  archive="$(cd "$(dirname "$argument")" && pwd)/$(basename "$argument")"
  archive_number=$((archive_number + 1))
  object_dir="$WORK_DIR/$archive_number"
  mkdir -p "$object_dir"

  (
    cd "$object_dir"
    /usr/bin/ar -x "$archive"
  )

  objects=("$object_dir"/*.o)
  if [[ ! -e "${objects[0]}" ]]; then
    echo "error: static archive contains no object files: $archive" >&2
    exit 1
  fi

  # Zig archives can contain unreadable, misaligned members that modern Apple
  # libtool silently drops. Extracting them produces properly aligned inputs.
  chmod u+r "${objects[@]}"
  arguments+=("${objects[@]}")
done

"$REAL_LIBTOOL" "${arguments[@]}"
