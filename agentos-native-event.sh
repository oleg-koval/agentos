#!/usr/bin/env bash
# Normalize native Claude Code, Codex, Hermes and Herdr hook input.
#
# This hook is intentionally observer-only. It never writes a decision to the
# agent's stdout and it forwards bounded metadata to the local AgentOS daemon.
set -euo pipefail

agent=''
source=''
dry_run="${AGENTOS_NATIVE_EVENT_DRY_RUN:-0}"
url="${AGENTOSD_URL:-http://127.0.0.1:4787}"

usage() {
  cat <<'EOF'
Usage: agentos-native-event --agent claude|codex|hermes|herdr

Reads the native hook JSON document from stdin and forwards a bounded,
observer-only AgentOS event. Set AGENTOS_NATIVE_EVENT_DRY_RUN=1 to print the
normalized event instead of posting it.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) agent="${2:-}"; shift 2 ;;
    --source) source="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$agent" in
  claude|codex|hermes|herdr) ;;
  *) echo '--agent must be claude, codex, hermes or herdr.' >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo 'jq is required.' >&2; exit 1; }

input="$(cat)"
if ! jq -e . >/dev/null 2>&1 <<<"$input"; then
  echo 'Native hook input must be valid JSON.' >&2
  exit 2
fi

event="$(jq -r '.hook_event_name // .event_type // .event // empty' <<<"$input")"
session="$(jq -r '.session_id // .session // .session_key // empty' <<<"$input")"
cwd="$(jq -r '.cwd // .working_directory // empty' <<<"$input")"
tool="$(jq -r '.tool_name // .tool // empty' <<<"$input")"
model="$(jq -r '.model // .response_model // empty' <<<"$input")"
file_path="$(jq -r '.file_path // .path // .file?.path // .tool_input?.file_path // empty' <<<"$input")"
file_change_path="$(jq -r '.file_change?.path // .file?.path // empty' <<<"$input")"
file_operation_input="$(jq -r '.file_change?.operation // .operation // .file?.operation // .change_type // .change?.action // empty' <<<"$input")"
file_before="$(jq -r '.file_change?.before // .before // .file?.before // .previous // .old_string // .tool_input?.old_string // empty' <<<"$input")"
file_after="$(jq -r '.file_change?.after // .after // .file?.after // .current // .new_string // .tool_input?.new_string // empty' <<<"$input")"
old_path="$(jq -r '.old_path // .previous_path // .file?.old_path // .file_change?.old_path // .tool_input?.old_path // empty' <<<"$input")"
new_path="$(jq -r '.new_path // .current_path // .file?.new_path // .file_change?.new_path // .tool_input?.new_path // empty' <<<"$input")"
file_before_source="$(jq -r 'if (.file_change? | type) == "object" and (.file_change | has("before")) then "metadata" elif has("before") or ((.file? | type) == "object" and (.file | has("before"))) or has("previous") then "metadata" elif has("old_string") or ((.tool_input? | type) == "object" and (.tool_input | has("old_string"))) then "content" else empty end' <<<"$input")"
file_after_source="$(jq -r 'if (.file_change? | type) == "object" and (.file_change | has("after")) then "metadata" elif has("after") or ((.file? | type) == "object" and (.file | has("after"))) or has("current") then "metadata" elif has("new_string") or ((.tool_input? | type) == "object" and (.tool_input | has("new_string"))) then "content" else empty end' <<<"$input")"
status_input="$(jq -r '.status // .outcome // empty' <<<"$input")"
approval_choice="$(jq -r '.choice // .decision // .approval_state // empty' <<<"$input")"
approval_key="$(jq -r '.approval_id // .request_id // .tool_call_id // .tool_use_id // empty' <<<"$input")"
task_id="$(jq -r '(.task_id // .task?.id // .task?.task_id // empty) | if . == null then empty elif type == "string" or type == "number" then tostring else empty end' <<<"$input")"
task_title="$(jq -r '(.task_title // .task?.title // .task?.name // .prompt_title // empty) | if . == null then empty elif type == "string" then . else empty end' <<<"$input")"
artifact_kind="$(jq -r '(.artifact_kind // .artifact?.kind // .output?.kind // empty) | if . == null then empty elif type == "string" then . else empty end' <<<"$input")"
artifact_path="$(jq -r '(.artifact_path // .artifact?.path // .output?.path // empty) | if . == null then empty elif type == "string" then . else empty end' <<<"$input")"
artifact_url="$(jq -r '(.artifact_url // .artifact?.url // .output?.url // empty) | if . == null then empty elif type == "string" then . else empty end' <<<"$input")"
input_tokens="$(jq -r '(.usage?.input_tokens // .usage?.input // .input_tokens // .prompt_tokens // 0) | try tonumber catch 0' <<<"$input")"
output_tokens="$(jq -r '(.usage?.output_tokens // .usage?.output // .output_tokens // .completion_tokens // 0) | try tonumber catch 0' <<<"$input")"
total_tokens="$(jq -r '(.usage?.total_tokens // .usage?.total // .total_tokens // 0) | try tonumber catch 0' <<<"$input")"
approval_reason="$(jq -r '(.approval_reason // .reason // empty) | if . == null then empty elif type == "string" then . else empty end' <<<"$input")"

if [[ -z "$session" ]]; then
  session="${agent}:workspace"
fi

project='workspace'
if [[ -n "$cwd" && -d "$cwd" ]]; then
  if root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"; then
    project="$(basename "$root")"
  else
    project="$(basename "$cwd")"
  fi
fi

if [[ -z "$source" ]]; then
  source="native-${agent}"
fi

task_title="${task_title:0:1024}"
approval_reason="${approval_reason:0:1024}"

status=''
kind=''
text=''
tool_state=''
approval_state=''
approval_kind="$tool"
file_operation='modified'

if [[ -z "$file_path" ]]; then
  file_path="$file_change_path"
fi
if [[ -z "$file_path" && -n "$new_path" ]]; then
  file_path="$new_path"
elif [[ -z "$file_path" && -n "$old_path" ]]; then
  file_path="$old_path"
fi

bounded_file_metadata() {
  local value="$1"
  local source_kind="$2"
  local digest bytes
  [[ -n "$value" || "$source_kind" == present ]] || return 0
  if [[ "$value" == sha256:* || "$value" == path:* || "$value" == bytes:* ]]; then
    printf '%s' "${value:0:1024}"
    return 0
  fi
  if [[ "$source_kind" == path ]]; then
    printf 'path:%s' "${value:0:1000}"
    return 0
  fi
  digest="$(printf '%s' "$value" | sha256sum | cut -d' ' -f1)"
  bytes="$(printf '%s' "$value" | wc -c | tr -d ' ')"
  printf 'sha256:%s;bytes:%s' "$digest" "$bytes"
}

if [[ -n "$old_path" ]]; then
  file_before="$(bounded_file_metadata "$old_path" path)"
  file_before_source='present'
fi
if [[ -n "$new_path" ]]; then
  file_after="$(bounded_file_metadata "$new_path" path)"
  file_after_source='present'
fi
if [[ -n "$file_before" || "$file_before_source" == content || "$file_before_source" == metadata ]]; then
  file_before="$(bounded_file_metadata "$file_before" "${file_before_source:-metadata}")"
fi
if [[ -n "$file_after" || "$file_after_source" == content || "$file_after_source" == metadata ]]; then
  file_after="$(bounded_file_metadata "$file_after" "${file_after_source:-metadata}")"
fi

file_change_observed=0
if [[ "$event" == FileChanged || -n "$file_operation_input" || -n "$file_before" || -n "$file_after" || -n "$old_path" || -n "$new_path" ]]; then
  file_change_observed=1
fi

emit_lifecycle() {
  kind='agent.lifecycle'
  status="$1"
  text="$2"
}

case "$agent:$event" in
  claude:SessionStart|codex:SessionStart|herdr:SessionStart)
    emit_lifecycle RUNNING 'native session running' ;;
  claude:SessionEnd|codex:SessionEnd|herdr:SessionEnd)
    emit_lifecycle DONE 'native session ended' ;;
  claude:Stop|codex:Stop|herdr:Stop)
    emit_lifecycle WAITING 'native turn ended' ;;
  claude:PreToolUse|codex:PreToolUse|herdr:PreToolUse)
    kind='tool.started'; status='TOOL'; tool_state='running'; text="${tool:-tool} started" ;;
  claude:PostToolUse|codex:PostToolUse|herdr:PostToolUse)
    kind='tool.completed'; status='RUNNING'; tool_state='completed'; text="${tool:-tool} completed" ;;
  claude:PostToolUseFailure|codex:PostToolUseFailure|herdr:PostToolUseFailure)
    kind='tool.failed'; status='FAILED'; tool_state='failed'; text="${tool:-tool} failed" ;;
  claude:PermissionRequest|codex:PermissionRequest|herdr:PermissionRequest)
    kind='approval.requested'; status='WAITING'; approval_state='pending'; text="Approval requested by ${agent^}" ;;
  claude:PermissionDenied|codex:PermissionDenied|herdr:PermissionDenied)
    kind='approval.resolved'; status='RUNNING'; approval_state='denied'; text="Approval denied by ${agent^}" ;;
  claude:FileChanged|codex:FileChanged|herdr:FileChanged)
    kind='file.changed'; status='RUNNING'; text='native file change observed' ;;
  claude:TaskCreated|codex:TaskCreated|herdr:TaskCreated)
    kind='task.created'; status='RUNNING'; text='native task created' ;;
  claude:TaskCompleted|codex:TaskCompleted|herdr:TaskCompleted)
    kind='task.completed'; status='RUNNING'; text='native task completed' ;;
  hermes:on_session_start|hermes:session:start)
    emit_lifecycle RUNNING 'Hermes session running' ;;
  hermes:on_session_end|hermes:session:end|hermes:on_session_finalize)
    emit_lifecycle DONE 'Hermes session ended' ;;
  hermes:pre_tool_call)
    kind='tool.started'; status='TOOL'; tool_state='running'; text="${tool:-tool} started" ;;
  hermes:post_tool_call)
    case "${status_input,,}" in
      error|failed|blocked|cancelled|canceled) kind='tool.failed'; status='FAILED'; tool_state="${status_input,,}" ;;
      *) kind='tool.completed'; status='RUNNING'; tool_state='completed' ;;
    esac
    text="${tool:-tool} ${tool_state}" ;;
  hermes:pre_approval_request)
    kind='approval.requested'; status='WAITING'; approval_state='pending'; text='Approval requested by Hermes' ;;
  hermes:post_approval_response)
    kind='approval.resolved'; status='RUNNING'
    case "${approval_choice,,}" in
      deny|denied|timeout|cancelled|canceled|smart_deny) approval_state='denied' ;;
      *) approval_state='approved' ;;
    esac
    text="Approval ${approval_state} by Hermes" ;;
  hermes:subagent_start)
    kind='agent.lifecycle'; status='STARTING'; text='Hermes subagent started' ;;
  hermes:subagent_stop)
    kind='agent.lifecycle'; status='DONE'; text='Hermes subagent ended' ;;
  *)
    # Unknown/additive hook events are intentionally ignored until their input
    # contract is mapped. A native hook must never create guessed state.
    exit 0
    ;;
esac

if [[ "$file_change_observed" == 1 ]]; then
  case "${file_operation_input,,}" in
    add|added|create|created) file_operation='added' ;;
    delete|deleted|remove|removed) file_operation='deleted' ;;
    rename|renamed|move|moved) file_operation='renamed' ;;
    modify|modified|edit|edited|write|written) file_operation='modified' ;;
    *)
      if [[ -n "$old_path" && -n "$new_path" && "$old_path" != "$new_path" ]]; then
        file_operation='renamed'
      elif [[ -n "$file_before" && -z "$file_after" ]]; then
        file_operation='deleted'
      elif [[ -z "$file_before" && -n "$file_after" ]]; then
        file_operation='added'
      else
        file_operation='modified'
      fi
      ;;
  esac
else
  file_path=''
  file_before=''
  file_after=''
fi

if [[ -z "$session" ]]; then
  session="${agent}:${project}"
fi

approval_id=''
if [[ "$kind" == approval.* ]]; then
  [[ -n "$approval_key" ]] || approval_key="$tool"
  approval_id="$(printf '%s\0' "$agent" "$session" "$approval_key" | sha256sum | cut -d' ' -f1)"
fi

payload="$(jq -nc \
  --arg kind "$kind" \
  --arg text "$text" \
  --arg agent "$agent" \
  --arg status "$status" \
  --arg project "$project" \
  --arg session "$session" \
  --arg source "$source" \
  --arg model "$model" \
  --arg task_id "$task_id" \
  --arg task_title "$task_title" \
  --arg artifact_kind "$artifact_kind" \
  --arg artifact_path "$artifact_path" \
  --arg artifact_url "$artifact_url" \
  --argjson input_tokens "$input_tokens" \
  --argjson output_tokens "$output_tokens" \
  --argjson total_tokens "$total_tokens" \
  --arg tool "$tool" \
  --arg tool_state "$tool_state" \
  --arg approval_id "$approval_id" \
  --arg approval_kind "$approval_kind" \
  --arg approval_state "$approval_state" \
  --arg approval_reason "$approval_reason" \
  --arg file_path "$file_path" \
  --arg file_operation "$file_operation" \
  --arg file_before "$file_before" \
  --arg file_after "$file_after" \
  '{kind:$kind,text:$text,agent:$agent,status:$status,project:$project,session:$session,source:$source,model:$model,
    usage:(if ($input_tokens+$output_tokens+$total_tokens)==0 then null else {input_tokens:$input_tokens,output_tokens:$output_tokens,total_tokens:$total_tokens} end),
    task:(if $task_title=="" and $task_id=="" then {} else {id:$task_id,title:$task_title,state:$status} end),
    tool:(if $tool=="" then {} else {name:$tool,state:$tool_state} end),
    artifact:(if $artifact_kind=="" and $artifact_path=="" and $artifact_url=="" then null else {kind:$artifact_kind,path:$artifact_path,url:$artifact_url} end),
    approval:(if $approval_id=="" then null else {id:$approval_id,kind:$approval_kind,state:$approval_state,reason:(if $approval_reason=="" then $text else $approval_reason end)} end),
    file_change:(if $file_path=="" then null else {path:$file_path,operation:$file_operation,before:$file_before,after:$file_after} end)}')"

if [[ "$kind" == "tool.failed" ]]; then
  telemetry_command="${AGENTOS_TELEMETRY_BIN:-agentos-telemetry}"
  if command -v "$telemetry_command" >/dev/null 2>&1; then
    "$telemetry_command" record agent_event_failure failure >/dev/null 2>&1 || true
  fi
fi

if [[ "$dry_run" == 1 ]]; then
  printf '%s\n' "$payload"
  exit 0
fi

curl -fsS --max-time 3 -X POST -H 'Content-Type: application/json' --data "$payload" "$url/v1/events" >/dev/null 2>&1 || true
