#!/usr/bin/env bash
# Prune old pre-pacman Btrfs snapshots and their matching /boot bundles.
set -euo pipefail

KEEP="${BTRFS_PACMAN_SNAPSHOT_KEEP:-20}"
SNAPSHOT_DIR="${BTRFS_SNAPSHOT_DIR:-/.snapshots}"
BOOT_SNAPSHOT_ROOT="${BTRFS_BOOT_SNAPSHOT_DIR:-$SNAPSHOT_DIR/boot}"
BOOT_CANDIDATE="${AGENTOS_BOOT_CANDIDATE:-/var/lib/agentos/boot-candidate.json}"

[[ "$KEEP" =~ ^[0-9]+$ ]] || { echo 'BTRFS_PACMAN_SNAPSHOT_KEEP must be an integer.' >&2; exit 2; }

if [[ "$(findmnt -no FSTYPE / 2>/dev/null || true)" != btrfs || ! -d "$SNAPSHOT_DIR" ]]; then
  exit 0
fi

protected=''
if [[ -f "$BOOT_CANDIDATE" ]] && command -v jq >/dev/null 2>&1; then
  protected="$(jq -r '.snapshot // empty' "$BOOT_CANDIDATE" 2>/dev/null || true)"
fi

mapfile -t snapshots < <(
  find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d -name 'pre-pacman-*' -printf '%f\n' | sort -r
)

if (( ${#snapshots[@]} > KEEP )); then
  for ((i=KEEP; i<${#snapshots[@]}; i++)); do
    [[ -n "$protected" && "${snapshots[$i]}" == "$protected" ]] && {
      echo "Keeping AgentOS armed recovery snapshot: ${snapshots[$i]}"
      continue
    }
    path="$SNAPSHOT_DIR/${snapshots[$i]}"
    if btrfs subvolume show "$path" >/dev/null 2>&1; then
      echo "Pruning old pacman snapshot: $path"
      btrfs subvolume delete "$path"
      rm -rf "$BOOT_SNAPSHOT_ROOT/${snapshots[$i]}"
    fi
  done
fi

# Clean boot bundles left behind by interrupted/manual snapshot deletion.
if [[ -d "$BOOT_SNAPSHOT_ROOT" ]]; then
  while IFS= read -r bundle; do
    name="$(basename "$bundle")"
    [[ -e "$SNAPSHOT_DIR/$name" ]] || {
      echo "Pruning orphaned boot bundle: $bundle"
      rm -rf "$bundle"
    }
  done < <(find "$BOOT_SNAPSHOT_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'pre-pacman-*' -print)

  find "$BOOT_SNAPSHOT_ROOT" -mindepth 1 -maxdepth 1 -type d -name '.*.partial.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
fi
