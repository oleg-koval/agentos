#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="$tmp/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/agentos" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  version) echo 'AgentOS 0.1.0 (stable)' ;;
  health) echo 'agentos health must not be collected' >&2; exit 99 ;;
  'repository status') echo 'repository: ok' ;;
  *) exit 2 ;;
esac
EOF
cat > "$fake_bin/workstation-doctor" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == --check ]] || exit 2
printf '%s\n' \
  'health: ok' \
  'API_''KEY=doctor-api-value' \
  'api-''key: doctor-api-value-two' \
  'Author''ization: Bear''er authorization-value' \
  'Cook''ie: session=cookie-value' \
  'Set-''Cookie: refresh=set-cookie-value' \
  '-----BEGIN OPENSSH PRIV''ATE KEY-----' \
  'private-key-value' \
  '-----END OPENSSH PRIV''ATE KEY-----'
for index in {1..85}; do
  printf 'doctor line %s\n' "$index"
done
EOF
cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo 'No failed units.'
EOF
cat > "$fake_bin/journalctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' \
  '{"PRIORITY":"3","MESSAGE":"prompt and document content"}' \
  '{"PRIORITY":"3","MESSAGE":"pass''word=journal-value"}' \
  '{"PRIORITY":"4","MESSAGE":"/home/private-user/diagnostic.log"}'
EOF
cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  if [[ "$argument" == @* ]]; then
    cp "${argument#@}" "${TELEMETRY_CAPTURE:?}"
  fi
done
EOF
chmod 755 "$fake_bin"/*

export HOME="$tmp/home"
export XDG_CONFIG_HOME="$tmp/config"
export XDG_STATE_HOME="$tmp/state"
export PATH="$fake_bin:$PATH"

status="$(bash "$repo_root/agentos-telemetry.sh" status)"
grep -Fq 'AgentOS telemetry: disabled' <<<"$status"
bash "$repo_root/agentos-telemetry.sh" record agent_event_failure >/dev/null
[[ ! -e "$tmp/state/agentos/telemetry.jsonl" ]]
bash "$repo_root/agentos-telemetry.sh" enable >/dev/null
bash "$repo_root/agentos-telemetry.sh" record agent_event_failure failure >/dev/null
if bash "$repo_root/agentos-telemetry.sh" record unsupported_event failure >/dev/null 2>&1; then
  echo 'unsupported telemetry event unexpectedly accepted' >&2
  exit 1
fi
if bash "$repo_root/agentos-telemetry.sh" record health_failure unknown >/dev/null 2>&1; then
  echo 'unsupported telemetry outcome unexpectedly accepted' >&2
  exit 1
fi
for _ in {1..20}; do
  bash "$repo_root/agentos-telemetry.sh" record agent_event_failure failure >/dev/null &
done
wait
jq -s -e 'length == 21 and .[0].schema == "agentos.telemetry/v1" and (.[0].id | type == "string") and .[0].event == "agent_event_failure" and .[0].outcome == "failure"' \
  "$tmp/state/agentos/telemetry.jsonl" >/dev/null
[[ "$(stat -c '%a' "$tmp/config/agentos/telemetry.conf" 2>/dev/null || stat -f '%Lp' "$tmp/config/agentos/telemetry.conf")" == 600 ]]
[[ "$(stat -c '%a' "$tmp/state/agentos/telemetry.jsonl" 2>/dev/null || stat -f '%Lp' "$tmp/state/agentos/telemetry.jsonl")" == 600 ]]
[[ "$(stat -c '%a' "$tmp/state/agentos/telemetry.lock" 2>/dev/null || stat -f '%Lp' "$tmp/state/agentos/telemetry.lock")" == 600 ]]
if bash "$repo_root/agentos-telemetry.sh" configure http://telemetry.example.invalid/v1/events >/dev/null 2>&1; then
  echo 'insecure telemetry endpoint unexpectedly accepted' >&2
  exit 1
fi
bash "$repo_root/agentos-telemetry.sh" configure https://telemetry.example.invalid/v1/events >/dev/null
TELEMETRY_CAPTURE="$tmp/telemetry-upload.jsonl" bash "$repo_root/agentos-telemetry.sh" upload >/dev/null
jq -s -e 'length == 21 and .[0].schema == "agentos.telemetry/v1" and (.[0].id | type == "string")' \
  "$tmp/telemetry-upload.jsonl" >/dev/null
! grep -Eiq 'private-user|password|token|prompt|/home/' "$tmp/telemetry-upload.jsonl"
[[ ! -s "$tmp/state/agentos/telemetry.jsonl" ]]
bash "$repo_root/agentos-telemetry.sh" disable >/dev/null
[[ "$(wc -l < "$tmp/state/agentos/telemetry.jsonl")" -eq 0 ]]

report_parent="$tmp/shared-reports"
mkdir -m 755 "$report_parent"
report="$report_parent/report.md"
bash "$repo_root/agentos-support.sh" --output "$report" --include-logs >/dev/null
grep -Fq 'AgentOS support report' "$report"
grep -Fq 'health: ok' "$report"
grep -Fq 'API_KEY=<redacted>' "$report"
grep -Fq 'api-key: <redacted>' "$report"
grep -Fq 'Authorization: <redacted>' "$report"
grep -Fq 'Cookie: <redacted>' "$report"
grep -Fq 'Set-Cookie: <redacted>' "$report"
grep -Fq '<private key block redacted>' "$report"
grep -Fq '[output truncated]' "$report"
grep -Fq 'Error: 2' "$report"
grep -Fq 'Warning: 1' "$report"
! grep -Eiq 'doctor-api-value|authorization-value|cookie-value|set-cookie-value|private-key-value|prompt and document content|journal-value|private-user|BEGIN .*PRIVATE KEY|END .*PRIVATE KEY|doctor line 85' "$report"
mode="$(stat -c '%a' "$report" 2>/dev/null || stat -f '%Lp' "$report")"
[[ "$mode" == 600 ]]
[[ "$(stat -c '%a' "$report_parent" 2>/dev/null || stat -f '%Lp' "$report_parent")" == 755 ]]

printf 'keep me\n' > "$tmp/existing-report.md"
if bash "$repo_root/agentos-support.sh" --output "$tmp/existing-report.md" >/dev/null 2>&1; then
  echo 'existing support report unexpectedly overwritten' >&2
  exit 1
fi
grep -Fxq 'keep me' "$tmp/existing-report.md"
ln -s "$tmp/existing-report.md" "$tmp/report-link.md"
if bash "$repo_root/agentos-support.sh" --output "$tmp/report-link.md" >/dev/null 2>&1; then
  echo 'support report symlink unexpectedly followed' >&2
  exit 1
fi
grep -Fxq 'keep me' "$tmp/existing-report.md"

echo 'AgentOS support and telemetry tests passed.'
