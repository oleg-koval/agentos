#!/usr/bin/env bash
# Create encrypted portable Hermes backups for migration/disaster recovery.
set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
MODE="${1:---full}"
BACKUP_DIR="${HERMES_BACKUP_DIR:-$HOME/.local/share/hermes-backups}"
RECIPIENTS_FILE="${HERMES_BACKUP_AGE_RECIPIENTS:-$HOME/.config/agentos/hermes-backup-recipients.txt}"
if [[ ! -e "$RECIPIENTS_FILE" && -e "$HOME/.config/legacy-workstation/hermes-backup-recipients.txt" ]]; then
  RECIPIENTS_FILE="$HOME/.config/legacy-workstation/hermes-backup-recipients.txt"
fi

if [[ ${EUID} -eq 0 ]]; then
  echo 'Run hermes-backup as the workstation user, not root.' >&2
  exit 1
fi

if ! command -v hermes >/dev/null 2>&1; then
  echo 'Hermes is not installed yet; skipping backup.'
  exit 0
fi

if [[ ! -d "$HOME/.hermes" ]]; then
  echo 'Hermes has not been configured yet; skipping backup.'
  exit 0
fi

command -v age >/dev/null 2>&1 || {
  echo 'age is required for encrypted Hermes backups. Run sync-workstation.' >&2
  exit 1
}

install -d -m 700 "$BACKUP_DIR" "$(dirname "$RECIPIENTS_FILE")"

init_recipients() {
  if [[ -s "$RECIPIENTS_FILE" ]]; then
    return
  fi

  local authorized="$HOME/.ssh/authorized_keys"
  if [[ -r "$authorized" ]]; then
    awk '$1 == "ssh-ed25519" || $1 == "ssh-rsa" {print $1, $2}' "$authorized" > "$RECIPIENTS_FILE"
  fi

  if [[ ! -s "$RECIPIENTS_FILE" ]]; then
    rm -f "$RECIPIENTS_FILE"
    cat >&2 <<EOF
No age recipient is configured for Hermes backups.

Create:
  $RECIPIENTS_FILE

with one or more age recipients (age1...) or SSH public keys. The script can
auto-seed this file from plain ssh-ed25519/ssh-rsa lines in ~/.ssh/authorized_keys.
Keep the corresponding PRIVATE key somewhere other than this machine.
EOF
    return 1
  fi
  chmod 600 "$RECIPIENTS_FILE"
  echo "Initialized Hermes backup recipients from $authorized"
}

if ! init_recipients; then
  # Backups are optional until the operator configures an off-machine
  # recipient. Do not leave a recurring systemd unit failed on a fresh
  # workstation; workstation-doctor reports the missing backup separately.
  echo 'Hermes backup recipients are not configured; skipping backup.' >&2
  exit 0
fi

runtime_parent="${XDG_RUNTIME_DIR:-/tmp}"
if [[ ! -d "$runtime_parent" || ! -w "$runtime_parent" ]]; then
  runtime_parent=/tmp
fi
tmpdir="$(mktemp -d "$runtime_parent/hermes-backup.XXXXXX")"
chmod 700 "$tmpdir"
trap 'rm -rf "$tmpdir"' EXIT

# Encrypt plaintext archives left by older backup code or by a migration that
# could not encrypt immediately. Never delete plaintext until the .age copy was
# successfully written into the vault.
while IFS= read -r legacy; do
  [[ -n "$legacy" ]] || continue
  encrypted="${legacy}.age"
  if [[ ! -e "$encrypted" ]]; then
    echo "Encrypting legacy Hermes archive: $(basename "$legacy")"
    age -R "$RECIPIENTS_FILE" -o "$tmpdir/legacy.age" "$legacy"
    install -m 600 "$tmpdir/legacy.age" "$encrypted"
    rm -f "$tmpdir/legacy.age"
  fi
  rm -f "$legacy"
done < <(
  find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'hermes-*.zip' -o -name 'imported-*.zip' \) -print
)

stamp="$(date -u +%Y%m%d-%H%M%S)"
plain="$tmpdir/hermes-${stamp}.zip"

case "$MODE" in
  --quick)
    output="$BACKUP_DIR/hermes-quick-${stamp}.zip.age"
    hermes backup --quick --label automated -o "$plain"
    retention_pattern='hermes-quick-*.zip.age'
    retention_days=14
    ;;
  --full)
    output="$BACKUP_DIR/hermes-full-${stamp}.zip.age"
    hermes backup -o "$plain"
    retention_pattern='hermes-full-*.zip.age'
    retention_days=60
    ;;
  *)
    echo 'Usage: hermes-backup [--quick|--full]' >&2
    exit 2
    ;;
esac

chmod 600 "$plain"
age -R "$RECIPIENTS_FILE" -o "$tmpdir/final.age" "$plain"
install -m 600 "$tmpdir/final.age" "$output"
rm -f "$plain" "$tmpdir/final.age"

find "$BACKUP_DIR" -maxdepth 1 -type f -name "$retention_pattern" -mtime "+$retention_days" -delete
printf 'Encrypted Hermes backup created: %s\n' "$output"
printf 'Recipients: %s\n' "$RECIPIENTS_FILE"
