#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

helper="$tmp/agentos-config"
(cd "$repo_root/core" && go build -o "$helper" ./cmd/agentos-config)

fake_bin="$tmp/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -n ]] && shift
exec "$@"
EOF
cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "is-active sshd"|"--user is-active app-org.kde.krdpserver.service") exit 0 ;;
  "--user is-enabled hermes-backup-quick.timer")
    grep -Eq '^(quick|weekly)$' "$AGENTOS_TEST_BACKUP_STATE" && exit 0 || exit 1
    ;;
  "--user is-enabled hermes-backup-full.timer")
    grep -Eq '^(full|weekly)$' "$AGENTOS_TEST_BACKUP_STATE" && exit 0 || exit 1
    ;;
  "--global disable hermes-backup-quick.timer hermes-backup-full.timer") exit 0 ;;
  "--user disable --now hermes-backup-quick.timer") printf 'disabled\n' > "$AGENTOS_TEST_BACKUP_STATE"; exit 0 ;;
  "--user disable --now hermes-backup-full.timer") printf 'disabled\n' > "$AGENTOS_TEST_BACKUP_STATE"; exit 0 ;;
  "--user disable --now hermes-backup-quick.timer hermes-backup-full.timer") printf 'disabled\n' > "$AGENTOS_TEST_BACKUP_STATE"; exit 0 ;;
  "--user enable --now hermes-backup-quick.timer") printf 'quick\n' > "$AGENTOS_TEST_BACKUP_STATE"; exit 0 ;;
  "--user enable --now hermes-backup-full.timer") printf 'full\n' > "$AGENTOS_TEST_BACKUP_STATE"; exit 0 ;;
  "--user enable --now hermes-backup-quick.timer hermes-backup-full.timer") printf 'weekly\n' > "$AGENTOS_TEST_BACKUP_STATE"; exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat > "$fake_bin/tailscale" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "ip -4" ]] && printf '100.64.0.1\n'
EOF
cat > "$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == list ]] && printf 'NAME ID SIZE MODIFIED\nqwen-coder x 1 GB now\n'
EOF
for command in claude codex; do
  cat > "$fake_bin/$command" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done
chmod 755 "$fake_bin"/*
cat > "$fake_bin/agentos-power-policy" <<'EOF'
#!/usr/bin/env bash
printf 'power-policy %s\n' "$*" >> "${AGENTOS_TEST_LOG:?}"
EOF
chmod 755 "$fake_bin/agentos-power-policy"

root="$tmp/projects"
mkdir -p "$root"
recipient="$tmp/recipients"
printf 'age1example\n' > "$recipient"
channel="$tmp/channel"
printf 'stable\n' > "$channel"
printf 'full\n' > "$tmp/backup-state"
policy="$tmp/power-policy.conf"
cat > "$policy" <<'EOF'
[Sleep]
AllowSuspend=no
AllowHibernation=no
EOF
config="$tmp/config.yaml"
cat > "$config" <<EOF
version: 1
channel: stable
remote_access:
  ssh: true
  tailscale: true
  krdp: true
agents:
  claude: true
  codex: true
models:
  qwen-coder: true
project_roots:
  - "$root"
backup:
  enabled: true
  schedule: quick
  target: "$recipient"
power:
  sleep: disabled
  hibernate: disabled
EOF

export AGENTOS_CONFIG_HELPER="$helper"
export AGENTOS_CONFIG="$config"
export AGENTOS_CONFIG_STATE="$tmp/state.json"
export AGENTOS_CHANNEL_FILE="$channel"
export AGENTOS_SLEEP_POLICY_FILE="$policy"
export AGENTOS_TEST_BACKUP_STATE="$tmp/backup-state"
export PATH="$fake_bin:$PATH"

plan="$(bash "$repo_root/agentos-cli.sh" config plan --config "$config")"
jq -e '
  .schema == "agentos.config/v1" and
  .migration == "initial" and
  .config == "'$config'" and
  (.changes | map(select(.path == "remote_access.ssh"))[0].type == "bool") and
  (.changes | map(select(.path == "project_roots.'"$root"'"))[0].type == "path") and
  (.changes | map(select(.path == "backup.schedule"))[0].desired == "quick")
' <<<"$plan" >/dev/null
[[ ! -e "$tmp/state.json" ]] || { echo 'config plan wrote applied state' >&2; exit 1; }

applied="$(bash "$repo_root/agentos-cli.sh" config apply --config "$config")"
jq -e '.state == "applied"' <<<"$applied" >/dev/null
[[ -s "$tmp/state.json" ]] || { echo 'config apply did not persist state' >&2; exit 1; }
second_plan="$(bash "$repo_root/agentos-cli.sh" config plan --config "$config")"
jq -e '.state == "converged" and .migration == "none" and (.changes | all(.state == "satisfied"))' <<<"$second_plan" >/dev/null

second_apply="$(bash "$repo_root/agentos-cli.sh" config apply --config "$config")"
jq -e '.state == "applied" and .migration == "none"' <<<"$second_apply" >/dev/null

disabled_config="$tmp/disabled-backup.yaml"
sed 's/^  enabled: true$/  enabled: false/' "$config" > "$disabled_config"
disabled_state="$tmp/disabled-backup-state.json"
disabled_plan="$(AGENTOS_CONFIG_STATE="$disabled_state" bash "$repo_root/agentos-cli.sh" config plan --config "$disabled_config")"
jq -e '.changes | map(select(.path == "backup.schedule"))[0].desired == "disabled"' <<<"$disabled_plan" >/dev/null
disabled_apply="$(AGENTOS_CONFIG_STATE="$disabled_state" bash "$repo_root/agentos-cli.sh" config apply --config "$disabled_config")"
jq -e '.state == "applied"' <<<"$disabled_apply" >/dev/null
disabled_second_plan="$(AGENTOS_CONFIG_STATE="$disabled_state" bash "$repo_root/agentos-cli.sh" config plan --config "$disabled_config")"
jq -e '.state == "converged" and (.changes | all(.state == "satisfied"))' <<<"$disabled_second_plan" >/dev/null

"$helper" --config "$config" --state "$tmp/state.json" mark-applied >/dev/null
jq -e '.schema == "agentos.config-state/v1" and .version == 1 and (.config_hash | length == 64)' "$tmp/state.json" >/dev/null

bad="$tmp/bad.yaml"
sed 's/^  target:.*$/  target: relative-recipient/' "$config" > "$bad"
if "$helper" --config "$bad" --state "$tmp/bad-state.json" plan >"$tmp/bad.out" 2>&1; then
  echo 'relative backup target unexpectedly passed validation' >&2
  exit 1
fi
grep -Fq 'backup.target must be an absolute path' "$tmp/bad.out"

unknown="$tmp/unknown.yaml"
sed 's/^  claude: true$/  unknown-agent: true/' "$config" > "$unknown"
: > "$tmp/operations.log"
if bash "$repo_root/agentos-cli.sh" config apply --config "$unknown" >"$tmp/unknown.out" 2>&1; then
  echo 'unknown config capability unexpectedly applied' >&2
  exit 1
fi
grep -Fq 'Unknown capability: unknown-agent' "$tmp/unknown.out"
[[ ! -s "$tmp/operations.log" ]] || {
  echo 'config apply mutated before validating all capability names' >&2
  exit 1
}

clean_root="$tmp/clean-machine-projects"
mkdir -p "$clean_root"
clean_config="$tmp/clean-machine.yaml"
cat > "$clean_config" <<EOF
version: 1
channel: stable
remote_access:
  ssh: true
  tailscale: true
  krdp: true
agents:
models:
project_roots:
  - "$clean_root"
backup:
  enabled: true
  schedule: quick
  target: "$recipient"
power:
  sleep: disabled
  hibernate: disabled
EOF
clean_state="$tmp/clean-machine-state.json"
echo full > "$AGENTOS_TEST_BACKUP_STATE"
clean_plan="$(AGENTOS_CONFIG="$clean_config" AGENTOS_CONFIG_STATE="$clean_state" bash "$repo_root/agentos-cli.sh" config plan --config "$clean_config")"
jq -e '.migration == "initial" and .state == "pending"' <<<"$clean_plan" >/dev/null
clean_apply="$(AGENTOS_CONFIG="$clean_config" AGENTOS_CONFIG_STATE="$clean_state" bash "$repo_root/agentos-cli.sh" config apply --config "$clean_config")"
jq -e '.state == "applied"' <<<"$clean_apply" >/dev/null
clean_second_plan="$(AGENTOS_CONFIG="$clean_config" AGENTOS_CONFIG_STATE="$clean_state" bash "$repo_root/agentos-cli.sh" config plan --config "$clean_config")"
jq -e '.migration == "none" and .state == "converged" and (.changes | all(.state == "satisfied"))' <<<"$clean_second_plan" >/dev/null

example_plan="$("$helper" --config "$repo_root/config/agentos-config.example.yaml" --state "$tmp/example-state.json" plan)"
jq -e '.schema == "agentos.config/v1" and .version == 1 and (.changes | length > 0)' <<<"$example_plan" >/dev/null

missing="$tmp/missing.yaml"
if bash "$repo_root/agentos-cli.sh" config plan --config "$missing" >"$tmp/missing.out" 2>&1; then
  echo 'missing config unexpectedly passed plan' >&2
  exit 1
fi
grep -Fq 'run sudo agentos config init' "$tmp/missing.out"

init_config="$tmp/init.yaml"
init_home="$tmp/init-home"
AGENTOS_CONFIG_INIT_HELPER="$repo_root/ensure-agentos-config.sh" \
  AGENTOS_WORKSTATION_USER=agent AGENTOS_WORKSTATION_HOME="$init_home" \
  bash "$repo_root/agentos-cli.sh" config init --config "$init_config" >/dev/null
grep -Fqx 'version: 1' "$init_config"
grep -Fqx '  - "'$init_home'/src"' "$init_config"

echo 'AgentOS declarative config tests passed.'
