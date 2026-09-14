#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

config="$tmp/etc/agentos/config.yaml"
home="$tmp/home/agent"
mkdir -p "$home"

env \
  AGENTOS_CONFIG_FILE="$config" \
  AGENTOS_HOST_CONFIG="$tmp/host.conf" \
  AGENTOS_WORKSTATION_USER=agent \
  AGENTOS_WORKSTATION_HOME="$home" \
  bash "$repo_root/ensure-agentos-config.sh"

grep -Fqx 'version: 1' "$config"
grep -Fqx 'channel: stable' "$config"
grep -Fqx '  - "'$home'/src"' "$config"
grep -Fqx '  target: "'$home'/.config/agentos/hermes-backup-recipients.txt"' "$config"

helper="$tmp/agentos-config"
(cd "$repo_root/core" && go build -o "$helper" ./cmd/agentos-config)
plan="$(AGENTOS_CHANNEL_FILE="$tmp/channel" "$helper" --config "$config" --state "$tmp/state" plan)"
jq -e '.schema == "agentos.config/v1" and .version == 1' <<<"$plan" >/dev/null

printf 'custom configuration\n' > "$config"
env \
  AGENTOS_CONFIG_FILE="$config" \
  AGENTOS_HOST_CONFIG="$tmp/host.conf" \
  AGENTOS_WORKSTATION_USER=agent \
  AGENTOS_WORKSTATION_HOME="$home" \
  bash "$repo_root/ensure-agentos-config.sh"
grep -Fqx 'custom configuration' "$config"

rm -f "$config"
target="$tmp/custom-config.yaml"
printf 'user-owned configuration\n' > "$target"
ln -s "$target" "$config"
env \
  AGENTOS_CONFIG_FILE="$config" \
  AGENTOS_HOST_CONFIG="$tmp/host.conf" \
  AGENTOS_WORKSTATION_USER=agent \
  AGENTOS_WORKSTATION_HOME="$home" \
  bash "$repo_root/ensure-agentos-config.sh"
[[ "$(readlink "$config")" == "$target" ]]

for channel in beta edge none; do
  printf '%s\n' "$channel" > "$tmp/channel"
  env AGENTOS_CHANNEL_FILE="$tmp/channel" \
    AGENTOS_CONFIG_FILE="$tmp/$channel.yaml" AGENTOS_HOST_CONFIG="$tmp/host.conf" \
    AGENTOS_WORKSTATION_USER=agent AGENTOS_WORKSTATION_HOME="$home" \
    bash "$repo_root/ensure-agentos-config.sh"
  grep -Fqx "channel: $channel" "$tmp/$channel.yaml"
done
printf 'invalid\n' > "$tmp/channel"
if env AGENTOS_CHANNEL_FILE="$tmp/channel" \
  AGENTOS_CONFIG_FILE="$tmp/invalid.yaml" AGENTOS_HOST_CONFIG="$tmp/host.conf" \
  AGENTOS_WORKSTATION_USER=agent bash "$repo_root/ensure-agentos-config.sh"; then
  echo 'Invalid channel must fail before writing configuration.' >&2; exit 1
fi
[[ ! -e "$tmp/invalid.yaml" ]]

echo 'AgentOS first-run config initialization passed.'
