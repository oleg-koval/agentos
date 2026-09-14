#!/usr/bin/env bash
# Restore a portable Hermes backup onto this workstation.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: migrate-hermes <backup.zip|backup.zip.age> [--start]

Import a backup created with `hermes backup` or `hermes-backup`. The source
archive is preserved in the local Hermes backup vault before import. Encrypted
.age archives require HERMES_BACKUP_AGE_IDENTITY to point at an age identity or
SSH private key that can decrypt the archive.

For a plaintext .zip import, the helper creates a new encrypted full Hermes
backup after a successful import and removes the preserved plaintext copy only
when that encrypted backup succeeds.

Pass --start only after the source machine's Hermes gateway has been stopped;
this avoids two hosts polling the same Telegram bot token at once.
EOF
}

if [[ ${EUID} -eq 0 ]]; then
  echo 'Run migrate-hermes as the workstation user, not root.' >&2
  exit 1
fi

[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 2; }
archive="$1"
start_mode="${2:-}"
[[ "$start_mode" == '' || "$start_mode" == '--start' ]] || { usage; exit 2; }
[[ -f "$archive" ]] || { echo "Backup not found: $archive" >&2; exit 1; }
command -v hermes >/dev/null 2>&1 || { echo 'Hermes is not installed.' >&2; exit 1; }

backup_dir="$HOME/.local/share/hermes-backups"
install -d -m 700 "$backup_dir"
kept="$backup_dir/imported-$(date -u +%Y%m%d-%H%M%S)-$(basename "$archive")"
cp -p "$archive" "$kept"
chmod 600 "$kept"
printf 'Preserved source archive at: %s\n' "$kept"

runtime_parent="${XDG_RUNTIME_DIR:-/tmp}"
if [[ ! -d "$runtime_parent" || ! -w "$runtime_parent" ]]; then
  runtime_parent=/tmp
fi
tmpdir="$(mktemp -d "$runtime_parent/hermes-import.XXXXXX")"
trap 'rm -rf "$tmpdir" /tmp/hermes-mac-paths.$$' EXIT
import_archive="$kept"
source_was_plaintext=1

if [[ "$kept" == *.age ]]; then
  source_was_plaintext=0
  command -v age >/dev/null 2>&1 || { echo 'age is required to decrypt this backup. Run sync-workstation.' >&2; exit 1; }
  identity="${HERMES_BACKUP_AGE_IDENTITY:-}"
  [[ -n "$identity" && -r "$identity" ]] || {
    echo 'Encrypted backup requires HERMES_BACKUP_AGE_IDENTITY=/path/to/private-key.' >&2
    echo 'Use the private age/SSH key corresponding to the backup recipient.' >&2
    exit 1
  }
  import_archive="$tmpdir/hermes-import.zip"
  age -d -i "$identity" -o "$import_archive" "$kept"
  chmod 600 "$import_archive"
fi

# A stopped gateway gives the cleanest cutover. Ignore "not running" errors.
hermes gateway stop >/dev/null 2>&1 || true
hermes import "$import_archive" --force

# The imported ~/.hermes tree now exists, so install/update Herdr's Hermes
# integration here instead of waiting for another workstation sync. Hermes is
# still stopped at this point, so the plugin will be active on the next start.
if command -v herdr >/dev/null 2>&1; then
  echo
  echo 'Installing/updating Herdr Hermes integration.'
  herdr integration install hermes
fi

echo
if command -v rg >/dev/null 2>&1; then
  if rg -n '/Users/|/opt/homebrew' "$HOME/.hermes" >/tmp/hermes-mac-paths.$$ 2>/dev/null; then
    echo 'WARNING: macOS-specific absolute paths remain in the imported config:'
    cat /tmp/hermes-mac-paths.$$
    echo 'Update these paths to Linux equivalents before relying on the affected tools.'
  else
    echo 'No obvious macOS-specific absolute paths were found.'
  fi
  rm -f /tmp/hermes-mac-paths.$$
fi

echo
hermes doctor || echo 'Hermes doctor reported issues; review them before cutover.' >&2

if (( source_was_plaintext == 1 )); then
  echo
  echo 'Creating an encrypted post-import hard copy before removing the plaintext source archive.'
  if command -v hermes-backup >/dev/null 2>&1 && hermes-backup --full; then
    rm -f "$kept"
    echo 'Encrypted full backup created; preserved plaintext import copy removed.'
  else
    echo "WARNING: encrypted post-import backup failed; plaintext source remains at: $kept" >&2
    echo 'Configure an age recipient and run `hermes-backup --full`, then remove the plaintext copy manually.' >&2
  fi
fi

if [[ "$start_mode" == '--start' ]]; then
  echo
  echo 'Starting Hermes gateway on this workstation.'
  enable-hermes-gateway
else
  echo
  echo 'Import complete. Stop the Hermes gateway on the source Mac, then run:'
  echo '  enable-hermes-gateway'
fi
