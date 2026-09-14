#!/usr/bin/env bash
# Poll Herdr's semantic agent model and emit lifecycle changes into agentosd.
set -euo pipefail

INTERVAL="${AGENTOS_HERDR_BRIDGE_INTERVAL:-2}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agentos"
STATE_FILE="$STATE_DIR/herdr-bridge.tsv"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

command -v herdr >/dev/null 2>&1 || { echo 'herdr is not installed.' >&2; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'jq is required.' >&2; exit 1; }
command -v agentos-agent-event >/dev/null 2>&1 || { echo 'agentos-agent-event is required.' >&2; exit 1; }

project_from_cwd() {
  local cwd="$1" rest
  case "$cwd" in
    "$HOME/src/"*)
      rest="${cwd#"$HOME/src/"}"
      printf '%s\n' "${rest%%/*}"
      ;;
    *) printf '%s\n' workspace ;;
  esac
}

map_state() {
  case "${1,,}" in
    working) echo RUNNING ;;
    blocked) echo BLOCKED ;;
    done) echo DONE ;;
    idle) echo WAITING ;;
    *) echo RUNNING ;;
  esac
}

previous_state() {
  local key="$1"
  awk -F '\t' -v k="$key" '$1==k{print $2; exit}' "$STATE_FILE"
}

record_state() {
  local key="$1" state="$2" tmp
  tmp="$STATE_FILE.$$"
  awk -F '\t' -v k="$key" '$1!=k' "$STATE_FILE" > "$tmp" || true
  printf '%s\t%s\n' "$key" "$state" >> "$tmp"
  mv "$tmp" "$STATE_FILE"
}

poll_once() {
  local raw
  raw="$(herdr agent list 2>/dev/null || true)"
  [[ -n "$raw" ]] || return 0

  # Herdr's API response may nest AgentInfo objects. Extract any object carrying
  # semantic agent_status and normalize the fields we need. This intentionally
  # tolerates additive schema changes.
  jq -c '
    .. | objects |
    select(has("agent_status")) |
    {
      agent: (
        if (.agent? | type) == "string" then .agent
        elif (.agent_kind? | type) == "string" then .agent_kind
        elif (.detected_agent? | type) == "string" then .detected_agent
        elif (.display_agent? | type) == "string" then .display_agent
        else "" end
      ),
      state: (.agent_status // "unknown"),
      pane: (.pane_id // .terminal_id // ""),
      cwd: (.foreground_cwd // .cwd // ""),
      title: (.terminal_title_stripped // .terminal_title // "")
    } |
    select(.agent != "")
  ' <<<"$raw" | while IFS= read -r item; do
    local agent semantic mapped pane cwd project title key prev
    agent="$(jq -r '.agent' <<<"$item")"
    semantic="$(jq -r '.state' <<<"$item")"
    pane="$(jq -r '.pane' <<<"$item")"
    cwd="$(jq -r '.cwd' <<<"$item")"
    title="$(jq -r '.title' <<<"$item")"
    mapped="$(map_state "$semantic")"
    project="$(project_from_cwd "$cwd")"
    key="${agent}|${pane:-$project}"
    prev="$(previous_state "$key")"
    [[ "$prev" == "$mapped" ]] && continue

    agentos-agent-event \
      --agent "$agent" \
      --project "$project" \
      --session "$pane" \
      --status "$mapped" \
      --kind agent.lifecycle \
      --source herdr \
      --text "${title:-Herdr state: $semantic}" \
      >/dev/null 2>&1 || true
    record_state "$key" "$mapped"
  done
}

while true; do
  poll_once
  sleep "$INTERVAL"
done
