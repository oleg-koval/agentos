#!/usr/bin/env bash
# Validate a candidate AgentOS generation after boot. A failed candidate gets
# exactly one automatic rollback boot; loop protection prevents repeated reboot.
set -euo pipefail

STATE_DIR="${AGENTOS_STATE_DIR:-/var/lib/agentos}"
SNAPSHOT_DIR="${BTRFS_SNAPSHOT_DIR:-/.snapshots}"
STATE_CANDIDATE="$STATE_DIR/boot-candidate.json"
BOOT_STATE_DIR="${AGENTOS_BOOT_STATE_DIR:-/boot/agentos}"
BOOT_CANDIDATE="$BOOT_STATE_DIR/boot-candidate.json"
LAST_RESULT="$STATE_DIR/last-boot-health.json"
CONF="${AGENTOS_HOST_CONFIG:-${LEGACY_WORKSTATION_CONF:-/etc/agentos/host.conf}}"
if [[ ! -r "$CONF" && -r /etc/legacy-workstation.conf ]]; then CONF=/etc/legacy-workstation.conf; fi
MODE="${1:-check}"
TIMEOUT="${AGENTOS_BOOT_HEALTH_TIMEOUT:-90}"
NO_REBOOT="${AGENTOS_BOOT_HEALTH_NO_REBOOT:-0}"
BOOT_ID_FILE="${AGENTOS_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"

need_root() { [[ ${EUID} -eq 0 ]] || { echo 'agentos-boot-health must run as root.' >&2; exit 1; }; }
now() { date -Is; }
current_subvol() {
  local opts subvol
  opts="$(findmnt -no OPTIONS / 2>/dev/null || true)"
  subvol="$(tr ',' '\n' <<<"$opts" | sed -n 's/^subvol=//p' | head -n1)"
  printf '%s\n' "${subvol#/}"
}
workstation_user() {
  local user="${AGENTOS_WORKSTATION_USER:-${SUDO_USER:-}}"
  if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
    user="${WORKSTATION_USER:-$user}"
  fi
  [[ -n "$user" ]] || return 1
  printf '%s\n' "$user"
}
user_systemctl() {
  local user uid runtime
  user="$(workstation_user || true)"; [[ -n "$user" ]] || return 1
  uid="$(id -u "$user")"; runtime="/run/user/$uid"
  runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" systemctl --user "$@"
}
user_curl() {
  local user; user="$(workstation_user || true)"; [[ -n "$user" ]] || return 1
  runuser -u "$user" -- curl "$@"
}
listens() { ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[:.])$1$"; }
json_bool() { [[ "$1" == true ]] && printf true || printf false; }
boot_id() { cat "$BOOT_ID_FILE" 2>/dev/null || true; }
candidate_path() {
  if [[ -f "$BOOT_CANDIDATE" ]]; then
    printf '%s\n' "$BOOT_CANDIDATE"
  elif [[ -f "$STATE_CANDIDATE" ]]; then
    printf '%s\n' "$STATE_CANDIDATE"
  fi
}
copy_candidate_to_boot() {
  local tmp
  install -d -m 755 "$BOOT_STATE_DIR"
  tmp="$(mktemp "$BOOT_STATE_DIR/.boot-candidate.XXXXXX")"
  cp "$STATE_CANDIDATE" "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$BOOT_CANDIDATE"
}
remove_candidate() {
  rm -f "$STATE_CANDIDATE" "$BOOT_CANDIDATE"
}

write_result() {
  local status="$1" message="$2" generation="${3:-}" snapshot="${4:-}" attempts="${5:-0}"
  install -d -m 755 "$STATE_DIR"
  jq -n --arg status "$status" --arg message "$message" --arg generation "$generation" --arg snapshot "$snapshot" \
    --arg time "$(now)" --arg subvol "$(current_subvol)" --argjson attempts "$attempts" \
    '{status:$status,message:$message,generation:$generation,snapshot:$snapshot,time:$time,subvolume:$subvol,attempts:$attempts}' > "$LAST_RESULT"
  chmod 644 "$LAST_RESULT"
}

arm() {
  [[ $# -eq 3 ]] || { echo 'Usage: sudo agentos-boot-health arm GENERATION SNAPSHOT' >&2; exit 2; }
  local generation="$2" snapshot="$3" user krdp_enabled home_enabled armed_boot_id tmp
  user="$(workstation_user)"
  armed_boot_id="$(boot_id)"
  krdp_enabled=false; home_enabled=false
  user_systemctl is-enabled app-org.kde.krdpserver.service >/dev/null 2>&1 && krdp_enabled=true || true
  user_systemctl is-enabled agentos-home.service >/dev/null 2>&1 && home_enabled=true || true
  [[ -d "$SNAPSHOT_DIR/$snapshot" ]] || { echo "Recovery snapshot not found: $SNAPSHOT_DIR/$snapshot" >&2; exit 1; }

  # A successful convergence supersedes a rollback staged by an older failed
  # candidate. Never leave a stale one-shot boot entry armed underneath a new
  # GOOD generation.
  if rollback-workstation status 2>/dev/null | grep -Fq 'Staged rollback state:'; then
    echo 'Cancelling stale staged rollback before arming the new candidate.'
    rollback-workstation cancel
  fi

  install -d -m 755 "$STATE_DIR" "$BOOT_STATE_DIR"
  tmp="$(mktemp "$STATE_DIR/.boot-candidate.XXXXXX")"
  jq -n --arg generation "$generation" --arg snapshot "$snapshot" --arg user "$user" --arg armed_at "$(now)" --arg boot_id "$armed_boot_id" \
    --argjson krdp_enabled "$(json_bool "$krdp_enabled")" --argjson home_enabled "$(json_bool "$home_enabled")" \
    '{generation:$generation,snapshot:$snapshot,user:$user,armed_at:$armed_at,boot_id:$boot_id,attempts:0,krdp_enabled:$krdp_enabled,home_enabled:$home_enabled}' > "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$STATE_CANDIDATE"
  copy_candidate_to_boot
  echo "Armed boot health gate for generation $generation using $snapshot."
}

status() {
  local candidate; candidate="$(candidate_path || true)"
  if [[ -n "$candidate" ]]; then echo 'Candidate:'; jq . "$candidate"; else echo 'No boot candidate armed.'; fi
  if [[ -f "$LAST_RESULT" ]]; then echo; echo 'Last result:'; jq . "$LAST_RESULT"; fi
}

validate_once() {
  local krdp_expected="$1" home_expected="$2" failures=()
  systemctl is-active sshd.service >/dev/null 2>&1 && listens 22 || failures+=("SSH")
  [[ -n "$(tailscale ip -4 2>/dev/null | head -n1 || true)" ]] || failures+=("Tailscale")
  user_systemctl is-active agentosd.service >/dev/null 2>&1 || failures+=("agentosd")
  user_curl -fsS --max-time 2 http://127.0.0.1:4787/v1/healthz >/dev/null 2>&1 || failures+=("agentosd-health")
  if [[ "$home_expected" == true ]]; then user_systemctl is-active agentos-home.service >/dev/null 2>&1 || failures+=("AgentOS-Home"); fi
  if [[ "$krdp_expected" == true ]]; then
    user_systemctl is-active plasma-xdg-desktop-portal-kde.service >/dev/null 2>&1 || failures+=("KDE-portal")
    user_systemctl is-active app-org.kde.krdpserver.service >/dev/null 2>&1 || failures+=("KRDP")
    listens 3389 || failures+=("RDP-3389")
  fi
  if (( ${#failures[@]} )); then printf '%s\n' "${failures[*]}"; return 1; fi
  return 0
}

check() {
  local candidate; candidate="$(candidate_path || true)"
  [[ -n "$candidate" ]] || { echo 'No candidate boot to validate.'; exit 0; }
  local generation snapshot attempts krdp_expected home_expected candidate_boot_id running_boot_id subvol deadline failures='' tmp
  generation="$(jq -r '.generation' "$candidate")"; snapshot="$(jq -r '.snapshot' "$candidate")"
  attempts="$(jq -r '.attempts // 0' "$candidate")"; krdp_expected="$(jq -r '.krdp_enabled // false' "$candidate")"; home_expected="$(jq -r '.home_enabled // false' "$candidate")"
  candidate_boot_id="$(jq -r '.boot_id // empty' "$candidate")"; running_boot_id="$(boot_id)"

  if [[ -n "$candidate_boot_id" && -n "$running_boot_id" && "$candidate_boot_id" == "$running_boot_id" ]]; then
    echo "Candidate generation $generation is armed during the current boot; waiting for the next boot."
    exit 0
  fi

  subvol="$(current_subvol)"

  # A one-shot recovery boot reached userspace. It is the known pre-change state,
  # so consume the candidate and never schedule another automatic reboot.
  if [[ "$subvol" == @rollback-* ]]; then
    write_result ROLLED_BACK "recovery boot reached userspace" "$generation" "$snapshot" "$attempts"
    remove_candidate
    echo "Generation $generation rolled back successfully to $subvol."
    exit 0
  fi

  deadline=$((SECONDS + TIMEOUT))
  while (( SECONDS < deadline )); do
    if failures="$(validate_once "$krdp_expected" "$home_expected")"; then
      write_result GOOD "candidate boot passed protected invariants" "$generation" "$snapshot" "$attempts"
      remove_candidate
      echo "Candidate generation $generation passed boot health gate."
      exit 0
    fi
    sleep 3
  done

  if (( attempts >= 1 )); then
    write_result FAILED_SAFE "boot health failed after rollback attempt; automatic reboot blocked: $failures" "$generation" "$snapshot" "$attempts"
    echo "Boot health failed, but rollback attempt limit is exhausted. Not rebooting again." >&2
    echo "Failed invariants: $failures" >&2
    exit 1
  fi

  attempts=$((attempts + 1))
  install -d -m 755 "$STATE_DIR"
  tmp="$(mktemp "$STATE_DIR/.boot-candidate.XXXXXX")"
  jq --argjson attempts "$attempts" '.attempts=$attempts' "$candidate" > "$tmp"; chmod 600 "$tmp"; mv "$tmp" "$STATE_CANDIDATE"
  copy_candidate_to_boot
  write_result ROLLBACK_PENDING "candidate boot failed: $failures" "$generation" "$snapshot" "$attempts"

  echo "Candidate generation $generation failed boot health: $failures" >&2
  if ! rollback-workstation status 2>/dev/null | grep -Fq 'Staged rollback state:'; then
    rollback-workstation stage "$snapshot" || { write_result FAILED_SAFE "could not stage rollback: $failures" "$generation" "$snapshot" "$attempts"; exit 1; }
  fi
  echo "One-shot rollback staged from $snapshot." >&2
  if [[ "$NO_REBOOT" == 1 ]]; then echo 'Test mode: automatic reboot suppressed.' >&2; exit 1; fi
  systemctl reboot
}

need_root
case "$MODE" in
  arm) arm "$@" ;;
  check) check ;;
  status) status ;;
  *) echo 'Usage: agentos-boot-health <arm GENERATION SNAPSHOT|check|status>' >&2; exit 2 ;;
esac
