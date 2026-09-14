#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/core"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fake_bin="$tmp/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/pacman" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake_bin/pacman"

state_dir="$tmp/state"
mkdir -p "$state_dir"
channel_file="$tmp/channel"
pacman_conf="$tmp/pacman.conf"
pacman_inc="$tmp/agentos.conf"
: > "$pacman_conf"
cat > "$state_dir/repository.json" <<'EOF'
{"schema":"agentos.repository/v1","configured":true,"url":"https://example.invalid/agentos/edge","fingerprint":"3060184CFC884D14CB1D54F9CA25144B4E4DBA8E","include":""}
EOF

PATH="$fake_bin:$PATH" \
AGENTOS_REPOSITORY_TEST_MODE=1 \
PACMAN_CONF="$pacman_conf" \
AGENTOS_PACMAN_INCLUDE="$pacman_inc" \
AGENTOS_STATE_DIR="$state_dir" \
AGENTOS_CHANNEL_FILE="$channel_file" \
go run ./cmd/agentos-ops --entrypoint repository set-channel beta

grep -Fq 'Server = https://example.invalid/agentos/beta' "$pacman_inc"
[[ "$(cat "$channel_file")" == "beta" ]] || { echo "channel file was not updated" >&2; exit 1; }
jq -er '.url == "https://example.invalid/agentos/beta"' "$state_dir/repository.json" >/dev/null
jq -er '.channel_changed_at | length > 0' "$state_dir/repository.json" >/dev/null

# set-channel none must make the setting true of the machine, not just of the channel
# file: pacman keeps pulling AgentOS packages from the last configured channel
# otherwise. The trusted state is kept so switching back needs no configure arguments.
PATH="$fake_bin:$PATH" \
AGENTOS_REPOSITORY_TEST_MODE=1 \
PACMAN_CONF="$pacman_conf" \
AGENTOS_PACMAN_INCLUDE="$pacman_inc" \
AGENTOS_STATE_DIR="$state_dir" \
AGENTOS_CHANNEL_FILE="$channel_file" \
go run ./cmd/agentos-ops --entrypoint repository set-channel none

[[ "$(cat "$channel_file")" == "none" ]] || { echo "set-channel none did not write the channel file" >&2; exit 1; }
[[ ! -f "$pacman_inc" ]] || { echo "set-channel none left the pacman include in place: $(cat "$pacman_inc")" >&2; exit 1; }
# pacman reads pacman.conf, so the Include line has to go too. Deleting only the
# included file would leave pacman warning about a missing include forever.
if grep -Fq "Include = $pacman_inc" "$pacman_conf"; then
  echo "set-channel none left the AgentOS Include line in pacman.conf:" >&2
  cat "$pacman_conf" >&2
  exit 1
fi
jq -er '.configured == true' "$state_dir/repository.json" >/dev/null
jq -er '.fingerprint == "3060184CFC884D14CB1D54F9CA25144B4E4DBA8E"' "$state_dir/repository.json" >/dev/null

# Coming back must not need the configure arguments again.
PATH="$fake_bin:$PATH" \
AGENTOS_REPOSITORY_TEST_MODE=1 \
PACMAN_CONF="$pacman_conf" \
AGENTOS_PACMAN_INCLUDE="$pacman_inc" \
AGENTOS_STATE_DIR="$state_dir" \
AGENTOS_CHANNEL_FILE="$channel_file" \
go run ./cmd/agentos-ops --entrypoint repository set-channel stable

grep -Fq 'Server = https://example.invalid/agentos/stable' "$pacman_inc"
[[ "$(cat "$channel_file")" == "stable" ]] || { echo "channel file was not restored" >&2; exit 1; }

echo "set-channel.sh test passed."
