#!/usr/bin/env bash
# Non-mutating weekly maintenance report for the workstation.
set -euo pipefail

REPORT_DIR="${WORKSTATION_MAINTENANCE_DIR:-/var/lib/agentos/maintenance}"
if [[ -z "${WORKSTATION_MAINTENANCE_DIR:-}" && ! -d "$REPORT_DIR" && -d /var/lib/legacy-workstation/maintenance ]]; then
  REPORT_DIR=/var/lib/legacy-workstation/maintenance
fi

if [[ "${1:-}" == "--show" ]]; then
  if [[ -r "$REPORT_DIR/last-report.txt" ]]; then
    cat "$REPORT_DIR/last-report.txt"
    exit 0
  fi
  echo 'No maintenance report exists yet.' >&2
  exit 1
fi

if [[ ${EUID} -ne 0 ]]; then
  echo 'Run workstation-maintenance-check as root (normally via systemd).' >&2
  exit 1
fi

install -d -m 755 "$REPORT_DIR"
stamp="$(date -u +%Y%m%d-%H%M%S)"
report="$REPORT_DIR/${stamp}.txt"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

{
  printf 'Workstation maintenance report\n'
  printf 'Generated: %s\n' "$(date -u --iso-8601=seconds)"
  printf 'Host: %s\n' "$(hostname)"
  printf 'Kernel: %s\n' "$(uname -r)"
  printf '\nPacman updates:\n'

  if command -v checkupdates >/dev/null 2>&1; then
    set +e
    updates="$(checkupdates 2>&1)"
    status=$?
    set -e
    case "$status" in
      0)
        if [[ -n "$updates" ]]; then
          printf '%s\n' "$updates"
        else
          echo 'none'
        fi
        ;;
      2)
        echo 'none'
        ;;
      *)
        printf 'check failed (exit %s):\n%s\n' "$status" "$updates"
        ;;
    esac
  else
    echo 'checkupdates is unavailable (pacman-contrib missing)'
  fi

  printf '\nHealth:\n'
  if command -v workstation-doctor >/dev/null 2>&1; then
    set +e
    workstation-doctor --check
    doctor_status=$?
    set -e
    printf '\nDoctor exit status: %s\n' "$doctor_status"
  else
    echo 'workstation-doctor is not installed'
  fi
} | tee "$tmp"

install -m 644 "$tmp" "$report"
ln -sfn "$(basename "$report")" "$REPORT_DIR/last-report.txt"
find "$REPORT_DIR" -maxdepth 1 -type f -name '*.txt' -mtime +30 -delete

echo
printf 'Saved report: %s\n' "$report"
