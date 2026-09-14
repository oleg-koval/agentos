#!/usr/bin/env bash
# Emit structured lifecycle/tool/artifact events into the local AgentOS runtime.
set -euo pipefail

URL="${AGENTOSD_URL:-http://127.0.0.1:4787}"
agent=''; status=''; project=''; session=''; kind='agent.lifecycle'; text=''; task=''; task_id=''; tool=''; tool_state=''; artifact_kind=''; artifact_path=''; artifact_url=''; model=''; input_tokens=0; output_tokens=0; total_tokens=0; approval_id=''; approval_kind=''; approval_state=''; approval_reason=''; file_path=''; file_operation=''; file_before=''; file_after=''; source='hook'

usage() {
  cat <<'EOF'
Usage: agentos-agent-event --agent NAME [options]

Options:
  --status STATE       STARTING|RUNNING|THINKING|TOOL|WAITING|BLOCKED|BACKGROUND|DONE|FAILED
  --project NAME
  --session ID
  --kind KIND          default: agent.lifecycle
  --text TEXT
  --task TEXT
  --task-id ID
  --tool NAME
  --tool-state STATE
  --artifact-kind KIND
  --artifact-path PATH
  --artifact-url URL
  --model NAME
  --input-tokens N    Model input token count
  --output-tokens N   Model output token count
  --total-tokens N    Total token count
  --approval-id ID
  --approval-kind KIND
  --approval-state STATE
  --approval-reason TEXT
  --file-path PATH
  --file-operation OP  added|modified|deleted|renamed
  --file-before VALUE  Optional digest or previous path
  --file-after VALUE   Optional digest or new path
  --source NAME        default: hook

Examples:
  agentos-agent-event --agent codex --project roazon --status THINKING --task 'Fix CI'
  agentos-agent-event --agent claude --project roazon --status WAITING --text 'Approval required'
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) agent="$2"; shift 2 ;;
    --status) status="${2^^}"; shift 2 ;;
    --project) project="$2"; shift 2 ;;
    --session) session="$2"; shift 2 ;;
    --kind) kind="$2"; shift 2 ;;
    --text) text="$2"; shift 2 ;;
    --task) task="$2"; shift 2 ;;
    --task-id) task_id="$2"; shift 2 ;;
    --tool) tool="$2"; shift 2 ;;
    --tool-state) tool_state="$2"; shift 2 ;;
    --artifact-kind) artifact_kind="$2"; shift 2 ;;
    --artifact-path) artifact_path="$2"; shift 2 ;;
    --artifact-url) artifact_url="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --input-tokens) input_tokens="$2"; shift 2 ;;
    --output-tokens) output_tokens="$2"; shift 2 ;;
    --total-tokens) total_tokens="$2"; shift 2 ;;
    --approval-id) approval_id="$2"; shift 2 ;;
    --approval-kind) approval_kind="$2"; shift 2 ;;
    --approval-state) approval_state="$2"; shift 2 ;;
    --approval-reason) approval_reason="$2"; shift 2 ;;
    --file-path) file_path="$2"; shift 2 ;;
    --file-operation) file_operation="$2"; shift 2 ;;
    --file-before) file_before="$2"; shift 2 ;;
    --file-after) file_after="$2"; shift 2 ;;
    --source) source="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$agent" ]] || { echo '--agent is required.' >&2; exit 2; }
for count in "$input_tokens" "$output_tokens" "$total_tokens"; do
  [[ "$count" =~ ^[0-9]+$ ]] || { echo 'Token counts must be non-negative integers.' >&2; exit 2; }
done

payload="$(jq -nc \
  --arg kind "$kind" --arg text "$text" --arg agent "$agent" --arg status "$status" \
  --arg project "$project" --arg session "$session" --arg source "$source" \
  --arg task "$task" --arg task_id "$task_id" --arg tool "$tool" --arg tool_state "$tool_state" \
  --arg artifact_kind "$artifact_kind" --arg artifact_path "$artifact_path" --arg artifact_url "$artifact_url" \
  --arg model "$model" --argjson input_tokens "$input_tokens" --argjson output_tokens "$output_tokens" --argjson total_tokens "$total_tokens" \
  --arg approval_id "$approval_id" --arg approval_kind "$approval_kind" --arg approval_state "$approval_state" --arg approval_reason "$approval_reason" \
  --arg file_path "$file_path" --arg file_operation "$file_operation" --arg file_before "$file_before" --arg file_after "$file_after" \
  '{kind:$kind,text:$text,agent:$agent,status:$status,project:$project,session:$session,source:$source,model:$model,
    usage:(if ($input_tokens+$output_tokens+$total_tokens)==0 then null else {input_tokens:$input_tokens,output_tokens:$output_tokens,total_tokens:$total_tokens} end),
    task:(if $task=="" and $task_id=="" then {} else {id:$task_id,title:$task,state:$status} end),
    tool:(if $tool=="" then {} else {name:$tool,state:$tool_state} end),
    artifact:(if $artifact_kind=="" and $artifact_path=="" and $artifact_url=="" then null else {kind:$artifact_kind,path:$artifact_path,url:$artifact_url} end),
    approval:(if $approval_id=="" and $approval_kind=="" and $approval_state=="" and $approval_reason=="" then null else {id:$approval_id,kind:$approval_kind,state:$approval_state,reason:$approval_reason} end),
    file_change:(if $file_path=="" and $file_operation=="" and $file_before=="" and $file_after=="" then null else {path:$file_path,operation:$file_operation,before:$file_before,after:$file_after} end)}')"

curl -fsS --max-time 3 -X POST -H 'Content-Type: application/json' --data "$payload" "$URL/v1/events" >/dev/null
