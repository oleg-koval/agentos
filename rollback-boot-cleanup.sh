#!/usr/bin/env bash
# Clean a consumed/failed one-shot rollback after the machine returns to normal root.
set -euo pipefail

STATE_FILE="${WORKSTATION_ROLLBACK_STATE:-/var/lib/agentos/rollback.env}"
if [[ -z "${WORKSTATION_ROLLBACK_STATE:-}" && ! -f "$STATE_FILE" && -f /var/lib/legacy-workstation/rollback.env ]]; then
  STATE_FILE=/var/lib/legacy-workstation/rollback.env
fi
BOOT_ROOT="${BOOT_ROOT:-/boot}"

[[ ${EUID} -eq 0 ]] || { echo 'rollback-boot-cleanup must run as root.' >&2; exit 1; }
[[ -f "$STATE_FILE" ]] || exit 0

# shellcheck disable=SC1090
source "$STATE_FILE"
rollback_subvol="${ROLLBACK_SUBVOL:-}"
recovery_dir="${RECOVERY_DIR:-}"

opts="$(findmnt -no OPTIONS / 2>/dev/null || true)"
current="$(tr ',' '\n' <<<"$opts" | sed -n 's/^subvol=//p' | head -n1)"
current="${current#/}"

# If this boot is the staged rollback itself, retain its entry/bundle and state
# for inspection. The systemd-boot one-shot has already been consumed, so the
# next ordinary reboot still returns to the normal default entry.
if [[ -n "$rollback_subvol" && "$current" == "$rollback_subvol" ]]; then
  echo "Rollback root is active ($rollback_subvol); retaining recovery state for this boot."
  exit 0
fi

# We are back on a normal root after a consumed/failed/manual bypass of the
# one-shot. The EFI one-shot is already consumed, so only remove stale recovery
# artifacts; do not create another one-shot that could override a deliberate
# user boot choice.
rm -f "$BOOT_ROOT/loader/entries/agentos-rollback.conf" \
      "$BOOT_ROOT/loader/entries/agentos-rollback-lts.conf" \
      "$BOOT_ROOT/loader/entries/legacy-rollback.conf" \
      "$BOOT_ROOT/loader/entries/legacy-rollback-lts.conf"
if [[ -n "$recovery_dir" && ( "$recovery_dir" == "$BOOT_ROOT"/agentos-rollback/* || "$recovery_dir" == "$BOOT_ROOT"/legacy-rollback/* ) ]]; then
  rm -rf "$recovery_dir"
fi
rm -f "$STATE_FILE"

echo 'Consumed rollback recovery boot state cleaned; normal boot entries remain untouched.'
