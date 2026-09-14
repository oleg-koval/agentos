#!/usr/bin/env bash
# Opt-in, low-cardinality AgentOS reliability telemetry.
set -euo pipefail

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/agentos"
config_file="${AGENTOS_TELEMETRY_CONFIG:-$config_dir/telemetry.conf}"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/agentos"
queue_file="${AGENTOS_TELEMETRY_QUEUE:-$state_dir/telemetry.jsonl}"
queue_lock_file="$state_dir/telemetry.lock"

usage() {
  cat <<'EOF'
Usage: agentos-telemetry status|enable|disable|configure URL|record EVENT [success|failure]|upload

Telemetry is disabled by default. When enabled, only allow-listed event names,
coarse outcomes, timestamps, and the AgentOS schema are stored locally. No
prompts, commands, tool output, paths, usernames, project names, hostnames,
addresses, tokens, or document contents are collected. Upload is never
automatic; it requires an explicitly configured HTTPS endpoint and a separate
upload command.
EOF
}

enabled() {
  [[ -f "$config_file" ]] && grep -Eq '^[[:space:]]*enabled=true[[:space:]]*$' "$config_file"
}

configured_endpoint() {
  sed -n 's/^endpoint=//p' "$config_file" 2>/dev/null | head -n 1
}

write_config() {
  local value="$1" endpoint_value="${2:-$(configured_endpoint)}"
  install -d -m 700 "$config_dir"
  local tmp
  tmp="$(mktemp "$config_dir/.telemetry.XXXXXX")"
  {
    printf 'enabled=%s\n' "$value"
    [[ -n "$endpoint_value" ]] && printf 'endpoint=%s\n' "$endpoint_value"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$config_file"
}

write_setting() { write_config "$1"; }

validate_endpoint() {
  local endpoint="$1"
  [[ "$endpoint" == https://* && "$endpoint" != *[[:space:]]* && "$endpoint" != *'@'* ]] || {
    echo 'Telemetry endpoint must be an HTTPS URL without embedded credentials or whitespace.' >&2
    exit 2
  }
}

acquire_queue_lock() {
  install -d -m 700 "$state_dir"
  touch "$queue_lock_file"
  chmod 600 "$queue_lock_file"
  exec {queue_lock_fd}>"$queue_lock_file"
  flock "$queue_lock_fd"
}

record() {
  local event="$1" outcome="${2:-success}"
  case "$event" in
    agent_event_failure|health_failure|update_failure|command_failure) ;;
    *) echo 'Unsupported telemetry event.' >&2; exit 2 ;;
  esac
  [[ "$outcome" == success || "$outcome" == failure ]] || { echo 'Outcome must be success or failure.' >&2; exit 2; }
  if ! enabled; then
    echo 'AgentOS telemetry is disabled; event not recorded.'
    return 0
  fi
  local payload line event_id tmp timestamp queue_lock_fd
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  payload="$(jq -nc --arg event "$event" --arg outcome "$outcome" --arg timestamp "$timestamp" \
    '{schema:"agentos.telemetry/v1",event:$event,outcome:$outcome,timestamp:$timestamp}')"
  event_id="$(printf '%s' "$payload" | sha256sum | awk '{print $1}')"
  line="$(jq -nc --argjson payload "$payload" --arg id "$event_id" '$payload + {id:$id}')"
  acquire_queue_lock
  touch "$queue_file"
  chmod 600 "$queue_file"
  tmp="$(mktemp "$state_dir/.telemetry.XXXXXX")"
  { tail -n 99 "$queue_file" 2>/dev/null || true; printf '%s\n' "$line"; } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$queue_file"
  echo 'AgentOS telemetry event recorded locally.'
}

upload() {
  enabled || { echo 'AgentOS telemetry is disabled; nothing was uploaded.'; return 0; }
  local endpoint tmp queue_lock_fd
  acquire_queue_lock
  [[ -s "$queue_file" ]] || { echo 'AgentOS telemetry queue is empty.'; return 0; }
  endpoint="${AGENTOS_TELEMETRY_ENDPOINT:-$(configured_endpoint)}"
  [[ -n "$endpoint" ]] || { echo 'No telemetry endpoint is configured; use agentos-telemetry configure https://HOST/PATH.' >&2; exit 2; }
  validate_endpoint "$endpoint"
  command -v curl >/dev/null 2>&1 || { echo 'curl is required for telemetry upload.' >&2; exit 1; }
  curl --fail --silent --show-error --max-time 10 \
    -H 'Content-Type: application/x-ndjson' \
    --data-binary "@$queue_file" "$endpoint" >/dev/null
  tmp="$(mktemp "$state_dir/.telemetry-upload.XXXXXX")"
  chmod 600 "$tmp"
  mv -f "$tmp" "$queue_file"
  echo 'AgentOS telemetry uploaded and local queue cleared.'
}

case "${1:-status}" in
  status)
    if enabled; then
      if [[ -n "${AGENTOS_TELEMETRY_ENDPOINT:-$(configured_endpoint)}" ]]; then
        echo 'AgentOS telemetry: enabled (explicit upload configured)'
      else
        echo 'AgentOS telemetry: enabled (local queue only)'
      fi
    else
      echo 'AgentOS telemetry: disabled'
    fi
    echo "Config: $config_file"
    echo "Queue: $queue_file"
    if [[ -n "${AGENTOS_TELEMETRY_ENDPOINT:-$(configured_endpoint)}" ]]; then
      echo 'Upload endpoint: configured (HTTPS; URL hidden)'
    else
      echo 'Upload endpoint: not configured'
    fi
    if [[ -f "$queue_file" ]]; then
      echo "Queued events: $(wc -l < "$queue_file" | tr -d ' ')"
    else
      echo 'Queued events: 0'
    fi
    ;;
  enable)
    write_setting true
    echo 'AgentOS telemetry enabled. Only anonymous reliability events are stored locally.'
    ;;
  disable)
    write_setting false
    echo 'AgentOS telemetry disabled. Existing local events were retained.'
    ;;
  configure)
    (($# == 2)) || { usage >&2; exit 2; }
    validate_endpoint "$2"
    if enabled; then write_config true "$2"; else write_config false "$2"; fi
    echo 'AgentOS telemetry endpoint configured. Upload remains manual.'
    ;;
  record)
    (($# >= 2 && $# <= 3)) || { usage >&2; exit 2; }
    record "$2" "${3:-success}"
    ;;
  upload)
    (($# == 1)) || { usage >&2; exit 2; }
    upload
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
