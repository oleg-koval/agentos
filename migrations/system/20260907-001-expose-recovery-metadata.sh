#!/usr/bin/env bash
set -euo pipefail

root="${AGENTOS_MIGRATION_ROOT:-}"
boot_snapshots="$root/.snapshots/boot"
rollback_state="$root/var/lib/agentos/rollback.env"

if [[ -d "$boot_snapshots" ]]; then
  find "$boot_snapshots" -type d -exec chmod 755 {} +
  find "$boot_snapshots" -type f \( -name MANIFEST.sha256 -o -path '*/loader/loader.conf' -o -path '*/loader/entries/*.conf' \) -exec chmod 644 {} +
fi
if [[ -f "$rollback_state" ]]; then
  chmod 644 "$rollback_state"
fi
legacy_rollback_state="$root/var/lib/legacy-workstation/rollback.env"
if [[ -f "$legacy_rollback_state" ]]; then
  chmod 644 "$legacy_rollback_state"
fi
