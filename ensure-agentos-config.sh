#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${AGENTOS_CONFIG_FILE:-/etc/agentos/config.yaml}"
HOST_CONFIG="${AGENTOS_HOST_CONFIG:-/etc/agentos/host.conf}"
WORKSTATION_USER="${AGENTOS_WORKSTATION_USER:-${SUDO_USER:-}}"

if [[ ! -f "$HOST_CONFIG" && -f /etc/legacy-workstation.conf ]]; then
  HOST_CONFIG=/etc/legacy-workstation.conf
fi
if [[ -f "$HOST_CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$HOST_CONFIG"
  WORKSTATION_USER="${WORKSTATION_USER:-${AGENTOS_WORKSTATION_USER:-${SUDO_USER:-}}}"
fi

# Package hooks may run on systems that were never configured with a user. Do
# not invent one or create a config that points at an unrelated home directory.
[[ "$WORKSTATION_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ && "$WORKSTATION_USER" != root ]] || exit 0
[[ ! -e "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || exit 0

channel_file="${AGENTOS_CHANNEL_FILE:-/etc/agentos/channel}"
channel="${AGENTOS_CHANNEL:-$(cat "$channel_file" 2>/dev/null || printf stable)}"
case "$channel" in
  stable|beta|edge|none) ;;
  *) echo "Unsupported channel: $channel" >&2; exit 2 ;;
esac

user_home="${AGENTOS_WORKSTATION_HOME:-}"
if [[ -z "$user_home" ]]; then
  user_home="$(getent passwd "$WORKSTATION_USER" | cut -d: -f6)"
fi
user_home="${user_home:-/home/$WORKSTATION_USER}"

yaml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

project_root="$(yaml_escape "$user_home/src")"
backup_target="$(yaml_escape "$user_home/.config/agentos/hermes-backup-recipients.txt")"
install -d -m 755 "$(dirname "$CONFIG_FILE")"
config_tmp="$(mktemp "${CONFIG_FILE}.XXXXXX")"
cat > "$config_tmp" <<EOF
version: 1
channel: $channel
remote_access:
  ssh: true
  tailscale: false
  krdp: false
agents:
models:
project_roots:
  - "$project_root"
backup:
  enabled: false
  schedule: weekly
  target: "$backup_target"
power:
  sleep: disabled
  hibernate: disabled
EOF
install -m 644 "$config_tmp" "$CONFIG_FILE"
rm -f "$config_tmp"
