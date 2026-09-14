#!/usr/bin/env bash
# Stage a boot-consistent Btrfs rollback for exactly the next boot.
# Normal boot entries are never modified.
set -euo pipefail

SNAPSHOT_DIR="${BTRFS_SNAPSHOT_DIR:-/.snapshots}"
BOOT_SNAPSHOT_ROOT="${BTRFS_BOOT_SNAPSHOT_DIR:-$SNAPSHOT_DIR/boot}"
STATE_DIR="${AGENTOS_STATE_DIR:-${WORKSTATION_STATE_DIR:-/var/lib/agentos}}"
if [[ -z "${AGENTOS_STATE_DIR:-}${WORKSTATION_STATE_DIR:-}" && ! -f "$STATE_DIR/rollback.env" && -f /var/lib/legacy-workstation/rollback.env ]]; then
  STATE_DIR=/var/lib/legacy-workstation
fi
STATE_FILE="$STATE_DIR/rollback.env"
BOOT_ROOT="${BOOT_ROOT:-/boot}"
BOOT_ENTRY_DIR="$BOOT_ROOT/loader/entries"
RECOVERY_ROOT="$BOOT_ROOT/agentos-rollback"
ROLLBACK_ENTRY="$BOOT_ENTRY_DIR/agentos-rollback.conf"
ROLLBACK_LTS_ENTRY="$BOOT_ENTRY_DIR/agentos-rollback-lts.conf"
LEGACY_RECOVERY_ROOT="$BOOT_ROOT/legacy-rollback"
LEGACY_ROLLBACK_ENTRY="$BOOT_ENTRY_DIR/legacy-rollback.conf"
LEGACY_ROLLBACK_LTS_ENTRY="$BOOT_ENTRY_DIR/legacy-rollback-lts.conf"

usage() {
  cat <<'EOF'
Usage:
  sudo rollback-workstation list
  sudo rollback-workstation status
  sudo rollback-workstation stage <pre-pacman-snapshot>
  sudo rollback-workstation cancel
  sudo rollback-workstation cleanup

`stage` creates a writable @rollback-* subvolume, copies the matching pre-pacman
/boot bundle onto the EFI system partition, creates dedicated recovery entries,
and uses `bootctl set-oneshot` so only the next boot enters the rollback.
Normal arch.conf/arch-lts.conf entries are never rewritten. If the rollback boot
fails, a later reboot naturally returns to the normal entry.
EOF
}

need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo 'Run rollback-workstation with sudo.' >&2
    exit 1
  fi
}

current_subvol() {
  local opts subvol
  opts="$(findmnt -no OPTIONS /)"
  subvol="$(tr ',' '\n' <<<"$opts" | sed -n 's/^subvol=//p' | head -n1)"
  subvol="${subvol#/}"
  printf '%s\n' "${subvol:-@}"
}

root_device() {
  if [[ -n "${ROOT_DEVICE_OVERRIDE:-}" ]]; then
    printf '%s\n' "$ROOT_DEVICE_OVERRIDE"
    return
  fi
  findmnt -no SOURCE / | sed 's/\[.*$//'
}

mount_top_level() {
  if [[ -n "${BTRFS_TOP_LEVEL_DIR:-}" ]]; then
    TOP_MOUNT="$BTRFS_TOP_LEVEL_DIR"
    TOP_MOUNT_OWNED=0
    return
  fi
  TOP_MOUNT="$(mktemp -d /run/agentos-btrfs-top.XXXXXX)"
  TOP_MOUNT_OWNED=1
  mount -t btrfs -o subvolid=5 "$(root_device)" "$TOP_MOUNT"
}

unmount_top_level() {
  if [[ "${TOP_MOUNT_OWNED:-0}" == 1 && -n "${TOP_MOUNT:-}" && -d "$TOP_MOUNT" ]]; then
    umount "$TOP_MOUNT" 2>/dev/null || true
    rmdir "$TOP_MOUNT" 2>/dev/null || true
  fi
}

verify_boot_bundle() {
  local bundle="$1"
  [[ -d "$bundle" ]] || return 1
  [[ -f "$bundle/loader/entries/arch.conf" ]] || return 1
  if [[ -f "$bundle/MANIFEST.sha256" ]]; then
    (
      cd "$bundle"
      sha256sum -c MANIFEST.sha256 >/dev/null
    )
  fi
}

render_recovery_entry() {
  local source_entry="$1" dest_entry="$2" target_subvol="$3" snapshot_name="$4" boot_prefix="$5"
  local line key path rest rel
  : > "$dest_entry"
  while IFS= read -r line || [[ -n "$line" ]]; do
    read -r key path rest <<<"$line"
    case "$key" in
      title)
        printf 'title AgentOS rollback (%s)\n' "$snapshot_name" >> "$dest_entry"
        ;;
      linux|initrd)
        rel="${path#/}"
        [[ -f "$BOOT_ROOT/${boot_prefix#/}/$rel" ]] || {
          echo "Recovery boot artifact is missing: $BOOT_ROOT/${boot_prefix#/}/$rel" >&2
          return 1
        }
        if [[ -n "$rest" ]]; then
          printf '%s %s/%s %s\n' "$key" "$boot_prefix" "$rel" "$rest" >> "$dest_entry"
        else
          printf '%s %s/%s\n' "$key" "$boot_prefix" "$rel" >> "$dest_entry"
        fi
        ;;
      options)
        if grep -q 'rootflags=subvol=' <<<"$line"; then
          sed -E "s#rootflags=subvol=[^ ]+#rootflags=subvol=${target_subvol}#" <<<"$line" >> "$dest_entry"
        else
          printf '%s rootflags=subvol=%s\n' "$line" "$target_subvol" >> "$dest_entry"
        fi
        ;;
      *)
        printf '%s\n' "$line" >> "$dest_entry"
        ;;
    esac
  done < "$source_entry"
}

list_snapshots() {
  printf 'Current root: %s\n\n' "$(current_subvol)"
  echo 'Available pre-pacman snapshots:'
  local name marker
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if verify_boot_bundle "$BOOT_SNAPSHOT_ROOT/$name" >/dev/null 2>&1; then
      marker='boot-safe'
    else
      marker='root-only'
    fi
    printf '  %-42s %s\n' "$name" "$marker"
  done < <(find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d -name 'pre-pacman-*' -printf '%f\n' 2>/dev/null | sort -r)
}

show_status() {
  printf 'Current root subvolume: %s\n' "$(current_subvol)"
  if [[ -f "$STATE_FILE" ]]; then
    echo
    echo 'Staged rollback state:'
    cat "$STATE_FILE"
  else
    echo 'No rollback is staged.'
  fi
  echo
  echo 'Recovery entries:'
  [[ -f "$ROLLBACK_ENTRY" ]] && echo "  $ROLLBACK_ENTRY" || echo '  none'
  [[ -f "$ROLLBACK_LTS_ENTRY" ]] && echo "  $ROLLBACK_LTS_ENTRY" || true
  [[ -f "$LEGACY_ROLLBACK_ENTRY" ]] && echo "  $LEGACY_ROLLBACK_ENTRY (legacy)" || true
  [[ -f "$LEGACY_ROLLBACK_LTS_ENTRY" ]] && echo "  $LEGACY_ROLLBACK_LTS_ENTRY (legacy)" || true
}

stage_rollback() {
  local requested="$1" name source bundle target stamp stage_dir boot_prefix needed available
  name="$(basename "$requested")"
  source="$SNAPSHOT_DIR/$name"
  bundle="$BOOT_SNAPSHOT_ROOT/$name"

  [[ "$name" == pre-pacman-* ]] || { echo 'Snapshot must be a pre-pacman-* snapshot.' >&2; exit 2; }
  [[ ! -f "$STATE_FILE" ]] || { echo 'A rollback is already staged. Run `sudo rollback-workstation cancel` first.' >&2; exit 1; }
  btrfs subvolume show "$source" >/dev/null 2>&1 || { echo "Not a Btrfs snapshot: $source" >&2; exit 1; }
  verify_boot_bundle "$bundle" || { echo "Snapshot has no valid matching boot bundle: $bundle" >&2; exit 1; }

  stamp="$(date -u +%Y%m%d-%H%M%S)"
  target="@rollback-${stamp}"
  stage_dir="$RECOVERY_ROOT/$target"
  boot_prefix="/agentos-rollback/$target"

  needed="$(du -sb "$bundle" | awk '{print $1}')"
  available="$(df -B1 --output=avail "$BOOT_ROOT" | tail -n1 | tr -d ' ')"
  if [[ "$needed" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]] && (( needed + 16777216 > available )); then
    echo "Not enough free space on $BOOT_ROOT for the staged rollback boot bundle." >&2
    echo "Need roughly $needed bytes plus 16 MiB safety margin; available $available bytes." >&2
    exit 1
  fi

  install -d -m 755 "$STATE_DIR" "$BOOT_ENTRY_DIR" "$RECOVERY_ROOT"
  rm -rf "$RECOVERY_ROOT"/@rollback-* "$ROLLBACK_ENTRY" "$ROLLBACK_LTS_ENTRY"

  mount_top_level
  trap unmount_top_level EXIT
  [[ ! -e "$TOP_MOUNT/$target" ]] || { echo "Rollback target already exists: $target" >&2; exit 1; }
  btrfs subvolume snapshot "$source" "$TOP_MOUNT/$target"

  rollback_created=1
  cleanup_failed_stage() {
    if [[ "${rollback_created:-0}" == 1 && -n "${TOP_MOUNT:-}" && -e "$TOP_MOUNT/$target" ]]; then
      btrfs subvolume delete "$TOP_MOUNT/$target" >/dev/null 2>&1 || true
    fi
    rm -rf "$stage_dir" "$ROLLBACK_ENTRY" "$ROLLBACK_LTS_ENTRY" "$STATE_FILE"
    unmount_top_level
  }
  trap cleanup_failed_stage ERR

  install -d -m 755 "$stage_dir"
  cp -a "$bundle/." "$stage_dir/"

  render_recovery_entry "$bundle/loader/entries/arch.conf" "$ROLLBACK_ENTRY" "$target" "$name" "$boot_prefix"
  if [[ -f "$bundle/loader/entries/arch-lts.conf" ]]; then
    render_recovery_entry "$bundle/loader/entries/arch-lts.conf" "$ROLLBACK_LTS_ENTRY" "$target" "$name LTS" "$boot_prefix"
  fi

  {
    printf 'ROLLBACK_SUBVOL=%q\n' "$target"
    printf 'SOURCE_SNAPSHOT=%q\n' "$name"
    printf 'RECOVERY_DIR=%q\n' "$stage_dir"
    printf 'RECOVERY_ENTRY=%q\n' 'agentos-rollback.conf'
    printf 'STAGED_AT=%q\n' "$(date -u --iso-8601=seconds)"
  } > "$STATE_FILE"
  # This file contains only sanitized recovery identifiers and paths. Keep it
  # readable so the unprivileged desktop can show staged/next-boot state.
  chmod 644 "$STATE_FILE"

  bootctl set-oneshot agentos-rollback.conf

  rollback_created=0
  trap - ERR
  unmount_top_level
  trap - EXIT

  echo
  echo "Rollback staged from $name."
  echo "Next boot only will use root subvolume: $target"
  echo "Matching kernel/initrd files were copied to: $stage_dir"
  echo 'Normal arch.conf and arch-lts.conf were not changed.'
  echo 'Reboot when ready. A later reboot returns to the normal boot entry automatically.'
}

cancel_rollback() {
  local recovery_dir=''
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    recovery_dir="${RECOVERY_DIR:-}"
  fi

  # Explicitly make the next boot normal, replacing any staged one-shot variable.
  bootctl set-oneshot arch.conf >/dev/null 2>&1 || true
  rm -f "$ROLLBACK_ENTRY" "$ROLLBACK_LTS_ENTRY" \
    "$LEGACY_ROLLBACK_ENTRY" "$LEGACY_ROLLBACK_LTS_ENTRY" "$STATE_FILE"
  [[ -n "$recovery_dir" ]] && rm -rf "$recovery_dir"
  echo 'Rollback one-shot cancelled. The next boot will use arch.conf.'
  echo 'The writable @rollback-* subvolume is retained until cleanup.'
}

cleanup_rollbacks() {
  local current staged='' keep=3 i name
  current="$(current_subvol)"
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    staged="${ROLLBACK_SUBVOL:-}"
  fi

  mount_top_level
  trap unmount_top_level EXIT
  mapfile -t rollbacks < <(find "$TOP_MOUNT" -mindepth 1 -maxdepth 1 -type d -name '@rollback-*' -printf '%f\n' | sort -r)
  for ((i=keep; i<${#rollbacks[@]}; i++)); do
    name="${rollbacks[$i]}"
    [[ "$name" == "$current" || "$name" == "$staged" ]] && continue
    echo "Deleting old rollback subvolume: $name"
    btrfs subvolume delete "$TOP_MOUNT/$name"
    rm -rf "$RECOVERY_ROOT/$name" "$LEGACY_RECOVERY_ROOT/$name"
  done
  unmount_top_level
  trap - EXIT
}

main() {
  need_root
  if [[ -z "${BTRFS_TOP_LEVEL_DIR:-}" ]]; then
    [[ "$(findmnt -no FSTYPE / 2>/dev/null || true)" == btrfs ]] || { echo 'Root filesystem is not Btrfs.' >&2; exit 1; }
  fi

  case "${1:-}" in
    list) list_snapshots ;;
    status) show_status ;;
    stage)
      [[ $# -eq 2 ]] || { usage; exit 2; }
      stage_rollback "$2"
      ;;
    cancel) cancel_rollback ;;
    cleanup) cleanup_rollbacks ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
