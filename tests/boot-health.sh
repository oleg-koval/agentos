#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
state="$tmp/state"; mocks="$tmp/mocks"; mkdir -p "$state" "$mocks"
conf="$tmp/legacy.conf"; echo 'WORKSTATION_USER=root' > "$conf"

cat > "$mocks/findmnt" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_ROLLBACK_ROOT:-0}" == 1 ]]; then echo 'rw,subvol=/@rollback-test'; else echo 'rw,subvol=/@'; fi
EOF
cat > "$mocks/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  is-active) exit 0 ;;
  reboot) echo reboot >> "$MOCK_LOG"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$mocks/ss" <<'EOF'
#!/usr/bin/env bash
echo 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:*'
echo 'LISTEN 0 128 0.0.0.0:3389 0.0.0.0:*'
EOF
cat > "$mocks/tailscale" <<'EOF'
#!/usr/bin/env bash
[[ "${MOCK_TAILSCALE_DOWN:-0}" == 1 ]] && exit 0
echo 100.64.0.1
EOF
cat > "$mocks/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$mocks/runuser" <<'EOF'
#!/usr/bin/env bash
shift 2
[[ "${1:-}" == -- ]] && shift
if [[ "${1:-}" == env ]]; then
  shift
  while [[ "${1:-}" == *=* ]]; do shift; done
fi
exec "$@"
EOF
cat > "$mocks/rollback-workstation" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  status) echo 'No rollback is staged.' ;;
  stage) echo "stage $2" >> "$MOCK_LOG" ;;
esac
EOF
chmod +x "$mocks"/*

export PATH="$mocks:/usr/bin:/bin"
export AGENTOS_STATE_DIR="$state"
export AGENTOS_BOOT_STATE_DIR="$state/boot"
export LEGACY_WORKSTATION_CONF="$conf"
export MOCK_LOG="$tmp/actions.log"
export AGENTOS_BOOT_HEALTH_TIMEOUT=1
export AGENTOS_BOOT_HEALTH_NO_REBOOT=1
export AGENTOS_BOOT_ID_FILE="$tmp/boot-id"
printf 'boot-a\n' > "$AGENTOS_BOOT_ID_FILE"

write_candidate() {
  local attempts="${1:-0}"
  mkdir -p "$state" "$AGENTOS_BOOT_STATE_DIR"
  jq -n --argjson attempts "$attempts" '{generation:"g1",snapshot:"pre-pacman-test",user:"root",attempts:$attempts,krdp_enabled:false,home_enabled:false}' > "$state/boot-candidate.json"
  cp "$state/boot-candidate.json" "$AGENTOS_BOOT_STATE_DIR/boot-candidate.json"
}

# A candidate armed during the current boot must remain pending for the next boot.
current_boot_id="$(cat "$AGENTOS_BOOT_ID_FILE")"
jq -n --arg boot_id "$current_boot_id" '{generation:"g1",snapshot:"pre-pacman-test",user:"root",attempts:0,boot_id:$boot_id,krdp_enabled:false,home_enabled:false}' > "$state/boot-candidate.json"
mkdir -p "$AGENTOS_BOOT_STATE_DIR"
cp "$state/boot-candidate.json" "$AGENTOS_BOOT_STATE_DIR/boot-candidate.json"
bash "$repo_root/agentos-boot-health.sh" check
[[ -f "$state/boot-candidate.json" ]]
[[ -f "$AGENTOS_BOOT_STATE_DIR/boot-candidate.json" ]]

# Healthy candidate is consumed and marked GOOD.
write_candidate 0
bash "$repo_root/agentos-boot-health.sh" check
[[ ! -f "$state/boot-candidate.json" ]]
[[ ! -f "$AGENTOS_BOOT_STATE_DIR/boot-candidate.json" ]]
[[ "$(jq -r .status "$state/last-boot-health.json")" == GOOD ]]

# Missing workstation identity must fail both user-scoped invariants.
write_candidate 0
: > "$tmp/empty-host.conf"
if env -u AGENTOS_WORKSTATION_USER -u SUDO_USER -u WORKSTATION_USER \
  AGENTOS_HOST_CONFIG="$tmp/empty-host.conf" bash "$repo_root/agentos-boot-health.sh" check; then
  echo 'expected missing workstation identity to fail boot health' >&2
  exit 1
fi
[[ "$(jq -r .status "$state/last-boot-health.json")" == ROLLBACK_PENDING ]]
message="$(jq -r .message "$state/last-boot-health.json")"
[[ "$message" == *agentosd* && "$message" == *agentosd-health* ]]

# First unhealthy candidate stages one rollback and increments the attempt count.
write_candidate 0
if MOCK_TAILSCALE_DOWN=1 bash "$repo_root/agentos-boot-health.sh" check; then
  echo 'expected unhealthy check to fail' >&2
  exit 1
fi
[[ "$(jq -r .attempts "$state/boot-candidate.json")" == 1 ]]
[[ "$(jq -r .attempts "$AGENTOS_BOOT_STATE_DIR/boot-candidate.json")" == 1 ]]
[[ "$(jq -r .status "$state/last-boot-health.json")" == ROLLBACK_PENDING ]]
grep -Fq 'stage pre-pacman-test' "$tmp/actions.log"

# A second unhealthy normal boot is stopped by loop protection.
: > "$tmp/actions.log"
if MOCK_TAILSCALE_DOWN=1 bash "$repo_root/agentos-boot-health.sh" check; then
  echo 'expected loop-protected check to fail' >&2
  exit 1
fi
[[ "$(jq -r .status "$state/last-boot-health.json")" == FAILED_SAFE ]]
[[ ! -s "$tmp/actions.log" ]]

# Reaching the one-shot rollback root consumes the candidate without another reboot.
write_candidate 1
MOCK_ROLLBACK_ROOT=1 bash "$repo_root/agentos-boot-health.sh" check
[[ ! -f "$state/boot-candidate.json" ]]
[[ ! -f "$AGENTOS_BOOT_STATE_DIR/boot-candidate.json" ]]
[[ "$(jq -r .status "$state/last-boot-health.json")" == ROLLED_BACK ]]

echo 'Boot health validation passed.'
