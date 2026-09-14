#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/agentos-vps-install.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="$tmp/bin"
mkdir -p "$fake_bin" "$tmp/pacman.d" "$tmp/agentos"
printf '%s\n' '# test pacman configuration' > "$tmp/pacman.conf"
original_config="$(cat "$tmp/pacman.conf")"

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=''
while (($# > 0)); do
  [[ "$1" == -o ]] && output="$2" && shift
  shift
done
printf 'test key\n' > "$output"
EOF
cat > "$fake_bin/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${AGENTOS_TEST_BAD_KEY:-0}" == 1 ]]; then
  printf 'fpr:::::::::EAC73D1D595C8F7D809D42EB268D28C12D93BC1B:\n'
else
  printf 'fpr:::::::::3060184CFC884D14CB1D54F9CA25144B4E4DBA8E:\n'
fi
EOF
cat > "$fake_bin/pacman-key" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'pacman-key %s\n' "$*" >> "${AGENTOS_TEST_LOG:?}"
EOF
cat > "$fake_bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'pacman %s\n' "$*" >> "${AGENTOS_TEST_LOG:?}"
EOF
cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${AGENTOS_TEST_SSH_DOWN:-0}" == 1 && "$1" == is-active && "${3:-}" == sshd ]]; then exit 1; fi
exit 0
EOF
cat > "$fake_bin/ss" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'State Local Address:Port Peer Address:Port' 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:*'
EOF
cat > "$fake_bin/sshd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
cat > "$fake_bin/loginctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
cat > "$fake_bin/runuser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'runuser %s\n' "$*" >> "${AGENTOS_TEST_LOG:?}"
if [[ "${AGENTOS_TEST_AGENT_FAILURE:-0}" == 1 && " $* " == *' --agents '* ]]; then
  exit 1
fi
exit 0
EOF
cat > "$fake_bin/install-agent-tools" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
EOF
cat > "$fake_bin/getent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == passwd ]] || exit 2
printf '%s:x:1000:1000:Test User:%s:/bin/bash\n' "${2:?}" "${AGENTOS_TEST_HOME:?}"
EOF
cat > "$fake_bin/id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -u && "${2:-}" == agentos-test ]]; then
  printf '1000\n'
else
  /usr/bin/id "$@"
fi
EOF
cat > "$fake_bin/agentos-onboarding" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'onboarding %s\n' "$*" >> "${AGENTOS_TEST_LOG:?}"
EOF
cat > "$fake_bin/agentos-repository" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'repository %s\n' "$*" >> "${AGENTOS_TEST_LOG:?}"
EOF
cat > "$fake_bin/agentos-power-policy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'power-policy %s\n' "$*" >> "${AGENTOS_TEST_LOG:?}"
EOF
chmod 755 "$fake_bin"/*

test_user=agentos-test
env_base=(
  PATH="$fake_bin:$PATH"
  AGENTOS_VPS_TEST_MODE=1
  AGENTOS_VPS_PACMAN_CONF="$tmp/pacman.conf"
  AGENTOS_VPS_INCLUDE="$tmp/pacman.d/agentos.conf"
  AGENTOS_STATE_DIR="$tmp/agentos"
  AGENTOS_VPS_STATE_DIR="$tmp/vps-state"
  AGENTOS_VPS_CONFIG_FILE="$tmp/agentos/config.yaml"
  AGENTOS_VPS_ROLE_FILE="$tmp/agentos/role"
  AGENTOS_VPS_CHANNEL_FILE="$tmp/agentos/channel"
  AGENTOS_VPS_CREATE_PROJECT_ROOTS=0
  AGENTOS_TEST_HOME="$tmp"
  AGENTOS_TEST_LOG="$tmp/operations.log"
  AGENTOS_VPS_AGENT_INSTALLER="$fake_bin/install-agent-tools"
  PATH="$fake_bin:/usr/bin:/bin"
)

: > "$tmp/operations.log"
env "${env_base[@]}" bash "$script" --repo-url 'https://example.invalid/agentos/\$arch' \
  --repo-key-url https://example.invalid/agentos-repo-public.asc --user "$test_user" \
  --fingerprint 3060184cfc884d14cb1d54f9ca25144b4e4dba8e > "$tmp/plan.log"
grep -Fq 'Dry run only.' "$tmp/plan.log"
[[ ! -s "$tmp/operations.log" ]]
[[ "$(cat "$tmp/pacman.conf")" == "$original_config" ]]
[[ ! -e "$tmp/pacman.d/agentos.conf" ]]

env "${env_base[@]}" bash "$script" --repo-url 'https://example.invalid/agentos/\$arch' \
  --repo-key-url https://example.invalid/agentos-repo-public.asc --user "$test_user" \
  --fingerprint 3060184cfc884d14cb1d54f9ca25144b4e4dba8e --role vps --channel beta \
  --project-root "$tmp/projects" --agents claude,hermes --tailscale --krdp --yes > "$tmp/apply.log"
grep -Fq 'pacman -Syu --needed --noconfirm agentos-runtime agentos-shell' "$tmp/operations.log"
grep -Fq 'onboarding --local --tailscale --krdp' "$tmp/operations.log"
grep -Fq 'power-policy apply' "$tmp/operations.log"
grep -Fq "runuser -u $test_user -- env HOME=$tmp USER=$test_user PATH=$tmp/.local/bin:/usr/bin:/bin $fake_bin/install-agent-tools --agents claude,hermes" "$tmp/operations.log"
grep -Fq 'configure machine role vps and update channel beta' "$tmp/apply.log"
grep -Fqx 'beta' "$tmp/agentos/channel"
grep -Fqx 'vps' "$tmp/agentos/role"
grep -Fq 'channel: beta' "$tmp/agentos/config.yaml"
grep -Fq '  claude: true' "$tmp/agentos/config.yaml"
grep -Fq '  hermes: true' "$tmp/agentos/config.yaml"
grep -Fq "  - \"$tmp/projects\"" "$tmp/agentos/config.yaml"
if command -v go >/dev/null 2>&1; then
  (cd "$repo_root/core" && go build -o "$tmp/agentos-config" ./cmd/agentos-config)
  generated_plan="$("$tmp/agentos-config" --config "$tmp/agentos/config.yaml" --state "$tmp/generated-state" plan)"
  jq -e '.schema == "agentos.config/v1" and (.changes | type == "array")' <<<"$generated_plan" >/dev/null
fi
grep -Fq 'systemctl --user enable --now agentosd.service agentos-herdr-bridge.service' "$script"
grep -Fq 'systemctl --user enable agentos-home.service' "$script"
! grep -Fq 'systemctl --user enable --now agentosd.service agentos-herdr-bridge.service agentos-home.service' "$script"
grep -Fq 'Include = ' "$tmp/pacman.conf"
[[ "$(grep -c '^Include = ' "$tmp/pacman.conf")" -eq 1 ]]
jq -e '.schema == "agentos.repository/v1" and .configured == true and .fingerprint == "3060184CFC884D14CB1D54F9CA25144B4E4DBA8E"' \
  "$tmp/agentos/repository.json" >/dev/null

env "${env_base[@]}" bash "$script" --reset > "$tmp/reset.log"
grep -Fq 'Restored repository configuration' "$tmp/reset.log"
[[ "$(cat "$tmp/pacman.conf")" == "$original_config" ]]
[[ ! -e "$tmp/pacman.d/agentos.conf" ]]
[[ ! -e "$tmp/agentos/repository.json" ]]
[[ ! -e "$tmp/agentos/config.yaml" ]]
[[ ! -e "$tmp/agentos/role" ]]
[[ ! -e "$tmp/agentos/channel" ]]

# A no-flags invocation must default the repository URL, key URL, and
# fingerprint from release/repository.env instead of requiring every flag.
default_pacman_conf="$tmp/default-pacman.conf"
default_include="$tmp/default-pacman.d/agentos.conf"
default_state="$tmp/default-agentos"
default_vps_state="$tmp/default-vps-state"
printf '%s\n' '# test pacman configuration' > "$default_pacman_conf"
cat > "$tmp/repository.env" <<'ENV'
AGENTOS_REPO_BASE_URL=https://example.invalid/agentos
AGENTOS_SIGNING_FINGERPRINT=3060184CFC884D14CB1D54F9CA25144B4E4DBA8E
ENV

: > "$tmp/operations.log"
env "${env_base[@]}" \
  AGENTOS_VPS_PACMAN_CONF="$default_pacman_conf" \
  AGENTOS_VPS_INCLUDE="$default_include" \
  AGENTOS_STATE_DIR="$default_state" \
  AGENTOS_VPS_STATE_DIR="$default_vps_state" \
  AGENTOS_VPS_CONFIG_FILE="$default_state/config.yaml" \
  AGENTOS_VPS_ROLE_FILE="$default_state/role" \
  AGENTOS_VPS_CHANNEL_FILE="$default_state/channel" \
  AGENTOS_VPS_REPOSITORY_ENV="$tmp/repository.env" \
  bash "$script" --user "$test_user" --channel beta --yes > "$tmp/default-apply.log"
grep -Fqx 'Server = https://example.invalid/agentos/beta' "$default_include"
# The published Pages layout is flat per channel, and agentos-repository's
# repositoryBaseURL only accepts a URL whose last segment is the channel, so the
# default must not carry an $arch segment.
! grep -Fq '$arch' "$default_include"
grep -Fq 'pacman-key --add' "$tmp/operations.log"
jq -e '.fingerprint == "3060184CFC884D14CB1D54F9CA25144B4E4DBA8E"' "$default_state/repository.json" >/dev/null
env "${env_base[@]}" \
  AGENTOS_VPS_PACMAN_CONF="$default_pacman_conf" \
  AGENTOS_VPS_INCLUDE="$default_include" \
  AGENTOS_STATE_DIR="$default_state" \
  AGENTOS_VPS_STATE_DIR="$default_vps_state" \
  AGENTOS_VPS_CONFIG_FILE="$default_state/config.yaml" \
  AGENTOS_VPS_ROLE_FILE="$default_state/role" \
  AGENTOS_VPS_CHANNEL_FILE="$default_state/channel" \
  bash "$script" --reset > "$tmp/default-reset.log"
grep -Fq 'Restored repository configuration' "$tmp/default-reset.log"

# Repeated apply is the provider-neutral idempotence contract: it may create
# fresh recoverable backups, but it must not duplicate the managed Include.
: > "$tmp/operations.log"
for reapply in 1 2; do
  env "${env_base[@]}" bash "$script" --repo-url 'https://example.invalid/agentos/\$arch' \
    --repo-key-url https://example.invalid/agentos-repo-public.asc --user "$test_user" \
    --fingerprint 3060184cfc884d14cb1d54f9ca25144b4e4dba8e --channel beta \
    --project-root "$tmp/projects" --agents claude,hermes --yes > "$tmp/reapply-$reapply.log"
done
[[ "$(grep -c '^Include = ' "$tmp/pacman.conf")" -eq 1 ]]
[[ "$(find "$tmp/vps-state" -mindepth 1 -maxdepth 1 -type d -name 'backup-*' | wc -l | tr -d ' ')" -eq 3 ]]

if env "${env_base[@]}" bash "$script" --repo-url 'https://example.invalid/agentos/\$arch' \
  --repo-key-url https://example.invalid/agentos-repo-public.asc --user "$test_user" \
  --project-root /srv/unsafe --yes > "$tmp/unsafe.log" 2>&1; then
  echo 'project root outside the user home unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'project root must be inside' "$tmp/unsafe.log"

cp "$tmp/pacman.conf" "$tmp/configured.conf"
if env "${env_base[@]}" AGENTOS_TEST_SSH_DOWN=1 bash "$script" \
  --repo-url 'https://example.invalid/agentos/\$arch' \
  --repo-key-url https://example.invalid/agentos-repo-public.asc --user "$test_user" --yes > "$tmp/fail.log" 2>&1; then
  echo 'inactive SSH unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'sshd is not active' "$tmp/fail.log"
[[ "$(cat "$tmp/pacman.conf")" == "$(cat "$tmp/configured.conf")" ]]

env "${env_base[@]}" AGENTOS_TEST_AGENT_FAILURE=1 bash "$script" \
  --repo-url 'https://example.invalid/agentos/\$arch' \
  --repo-key-url https://example.invalid/agentos-repo-public.asc --user "$test_user" \
  --fingerprint 3060184cfc884d14cb1d54f9ca25144b4e4dba8e --agents codex --yes > "$tmp/agent-failure.log" 2>&1
grep -Fq 'optional agent installation failed; core AgentOS setup will continue.' "$tmp/agent-failure.log"
grep -Fq "sudo -H -u $test_user env PATH=$tmp/.local/bin:/usr/bin:/bin $fake_bin/install-agent-tools --agents codex" "$tmp/agent-failure.log"

# A downloaded signing key mismatch must fail before any package or config
# mutation. This protects copied installers from silently trusting a drifted
# repository key.
before_bad_key_config="$(cat "$tmp/pacman.conf")"
: > "$tmp/operations.log"
if env "${env_base[@]}" AGENTOS_TEST_BAD_KEY=1 bash "$script" \
  --repo-url 'https://example.invalid/agentos/\$arch' \
  --repo-key-url https://example.invalid/agentos-repo-public.asc --user "$test_user" \
  --fingerprint 3060184cfc884d14cb1d54f9ca25144b4e4dba8e --yes > "$tmp/bad-key.log" 2>&1; then
  echo 'mismatched repository key unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'fingerprint mismatch' "$tmp/bad-key.log"
[[ ! -s "$tmp/operations.log" ]]
[[ "$(cat "$tmp/pacman.conf")" == "$before_bad_key_config" ]]

if grep -Eq 'mkfs|wipefs|parted|fdisk|(^|[[:space:]])dd([[:space:]]|$)|StrictHostKeyChecking=no|UserKnownHostsFile=/dev/null|sshpass|ufw .*disable' "$script"; then
  echo 'VPS installer contains a destructive or access-bypassing operation' >&2
  exit 1
fi

echo 'AgentOS VPS installer tests passed.'
