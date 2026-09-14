#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

state_json="$tmp/state.json"
notify_log="$tmp/notify.log"
action_log="$tmp/action.log"
marker="$tmp/notified"

cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *' -X POST '* ]]; then
  printf '%s\n' "$*" >> "$AGENTOS_UPDATE_ACTION_LOG"
  exit 0
fi
cat "$AGENTOS_UPDATE_STATE_FIXTURE"
EOF
cat > "$tmp/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGENTOS_UPDATE_NOTIFY_LOG"
printf '%s\n' "${AGENTOS_UPDATE_NOTIFY_ACTION:-dismissed}"
EOF
chmod 755 "$tmp/bin/"*

run_notify() {
  PATH="$tmp/bin:$PATH" \
  AGENTOS_UPDATE_STATE_FIXTURE="$state_json" \
  AGENTOS_UPDATE_NOTIFY_LOG="$notify_log" \
  AGENTOS_UPDATE_ACTION_LOG="$action_log" \
  AGENTOS_UPDATE_NOTIFY_STATE="$marker" \
  AGENTOS_UPDATE_NOTIFY_ACTION="${1:-dismissed}" \
  bash "$repo_root/agentos-update-notify.sh"
}

cat > "$state_json" <<'EOF'
{"updates":{"status":"up-to-date","channel":"stable","current_version":"1.0","checked_at":"2026-09-07T08:00:00Z","arch_pending":0}}
EOF
run_notify
[[ ! -e "$notify_log" && ! -e "$action_log" && ! -e "$marker" ]]

cat > "$state_json" <<'EOF'
{"updates":{"status":"available","channel":"stable","current_version":"1.0","target_version":"1.1","checked_at":"2026-09-07T09:00:00Z","arch_pending":2}}
EOF
run_notify default
grep -Fq -- '--action=default=Open Update Center' "$notify_log"
grep -Fq 'update-center-open' "$action_log"
first_count="$(wc -l < "$notify_log" | tr -d ' ')"
cat > "$state_json" <<'EOF'
{"updates":{"status":"available","channel":"stable","current_version":"1.0","target_version":"1.1","checked_at":"2026-09-07T10:00:00Z","arch_pending":2}}
EOF
run_notify default
[[ "$(wc -l < "$notify_log" | tr -d ' ')" == "$first_count" ]]

cat > "$state_json" <<'EOF'
{"updates":{"status":"apply-failed","channel":"stable","current_version":"1.0","target_version":"1.1","checked_at":"2026-09-07T09:00:00Z","last_failure":"doctor failed","arch_pending":2}}
EOF
run_notify
[[ "$(wc -l < "$notify_log" | tr -d ' ')" -gt "$first_count" ]]
grep -Fq 'Update needs attention' "$notify_log"
failure_count="$(wc -l < "$notify_log" | tr -d ' ')"

cat > "$state_json" <<'EOF'
{"updates":{"status":"available","channel":"stable","current_version":"1.0","target_version":"1.1","checked_at":"2026-09-07T11:00:00Z","arch_pending":2}}
EOF
run_notify
[[ "$(wc -l < "$notify_log" | tr -d ' ')" == "$failure_count" ]]

echo 'update-notify.sh test passed.'
