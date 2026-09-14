#!/usr/bin/env bash
# Create a read-only root snapshot and matching /boot bundle before pacman changes.
set -euo pipefail

SNAPSHOT_DIR="${BTRFS_SNAPSHOT_DIR:-/.snapshots}"
BOOT_SNAPSHOT_ROOT="${BTRFS_BOOT_SNAPSHOT_DIR:-$SNAPSHOT_DIR/boot}"
BOOT_ROOT="${BOOT_ROOT:-/boot}"

if [[ "$(findmnt -no FSTYPE / 2>/dev/null || true)" != btrfs ]]; then
  exit 0
fi

install -d -m 755 "$SNAPSHOT_DIR" "$BOOT_SNAPSHOT_ROOT"
stamp="$(date -u +%Y%m%d-%H%M%S)"
name="pre-pacman-${stamp}"
while [[ -e "$SNAPSHOT_DIR/$name" || -e "$BOOT_SNAPSHOT_ROOT/$name" ]]; do
  name="pre-pacman-${stamp}-$$-$RANDOM"
done

target="$SNAPSHOT_DIR/$name"
bundle="$BOOT_SNAPSHOT_ROOT/$name"
bundle_tmp="$BOOT_SNAPSHOT_ROOT/.${name}.partial.$$"

cleanup_partial() {
  rm -rf "$bundle_tmp"
}
trap cleanup_partial EXIT

install -d -m 755 "$bundle_tmp/loader/entries"
shopt -s nullglob
entries=("$BOOT_ROOT"/loader/entries/arch*.conf)
shopt -u nullglob

if (( ${#entries[@]} == 0 )); then
  echo "No Arch systemd-boot entries found under $BOOT_ROOT/loader/entries; refusing an unbootable snapshot." >&2
  exit 1
fi

copy_artifact() {
  local path="$1" rel src dst
  rel="${path#/}"
  [[ -n "$rel" ]] || return 0
  src="$BOOT_ROOT/$rel"
  [[ -f "$src" ]] || { echo "Referenced boot artifact is missing: $src" >&2; exit 1; }
  dst="$bundle_tmp/$rel"
  install -d -m 755 "$(dirname "$dst")"
  cp -a "$src" "$dst"
}

for entry in "${entries[@]}"; do
  cp -a "$entry" "$bundle_tmp/loader/entries/$(basename "$entry")"
  chmod 644 "$bundle_tmp/loader/entries/$(basename "$entry")"
  while read -r key path _; do
    case "$key" in
      linux|initrd) copy_artifact "$path" ;;
    esac
  done < "$entry"
done

if [[ -f "$BOOT_ROOT/loader/loader.conf" ]]; then
  install -d -m 755 "$bundle_tmp/loader"
  cp -a "$BOOT_ROOT/loader/loader.conf" "$bundle_tmp/loader/loader.conf"
  chmod 644 "$bundle_tmp/loader/loader.conf"
fi

(
  cd "$bundle_tmp"
  find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256
  chmod 644 MANIFEST.sha256
)

btrfs subvolume snapshot -r / "$target"
mv "$bundle_tmp" "$bundle"
trap - EXIT

printf 'Created pre-pacman snapshot: %s\n' "$target"
printf 'Captured matching boot bundle: %s\n' "$bundle"
