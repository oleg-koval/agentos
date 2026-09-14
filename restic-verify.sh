#!/usr/bin/env bash
# Verify Restic repository integrity and perform a tiny restore smoke test.
set -euo pipefail

ENV_FILE="${RESTIC_ENV_FILE:-/etc/restic-backup.env}"

if [[ ${EUID} -ne 0 ]]; then
  echo 'Run restic-verify as root (normally via systemd).' >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Restic is not configured ($ENV_FILE missing); skipping verification."
  exit 0
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is not configured}"
: "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE is not configured}"

restic -r "$RESTIC_REPOSITORY" check

tmp="$(mktemp -d /tmp/restic-restore-smoke.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
restic -r "$RESTIC_REPOSITORY" restore latest --target "$tmp" --include /etc/hostname
[[ -s "$tmp/etc/hostname" ]] || { echo 'Restic restore smoke test did not restore /etc/hostname.' >&2; exit 1; }

printf 'Restic verification and restore smoke test passed. Restored hostname: %s\n' "$(cat "$tmp/etc/hostname")"
