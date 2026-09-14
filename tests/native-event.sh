#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
adapter="$repo_root/agentos-native-event.sh"

[[ -x "$adapter" ]] || { echo "Missing executable native event adapter: $adapter" >&2; exit 1; }

event() {
  AGENTOS_NATIVE_EVENT_DRY_RUN=1 "$adapter" --agent "$1"
}

payload="$(event claude <<'JSON'
{"hook_event_name":"PreToolUse","session_id":"claude-s1","cwd":"/home/admin/src/demo","tool_name":"Bash","model":"claude-sonnet","tool_input":{"command":"git status"}}
JSON
)"
[[ "$(jq -r '.kind' <<<"$payload")" == tool.started ]] || { echo "Claude tool event was not normalized: $payload" >&2; exit 1; }
[[ "$(jq -r '.status' <<<"$payload")" == TOOL ]] || { echo "Claude tool status was not preserved: $payload" >&2; exit 1; }
[[ "$(jq -r '.tool.name' <<<"$payload")" == Bash ]] || { echo "Claude tool name was not preserved: $payload" >&2; exit 1; }
[[ "$(jq -r '.tool_input // empty' <<<"$payload")" == "" ]] || { echo 'Raw tool input leaked into the event.' >&2; exit 1; }
[[ "$(jq -r '.file_change // empty' <<<"$payload")" == "" ]] || { echo 'Non-file tool input created a file change.' >&2; exit 1; }

payload="$(event codex <<'JSON'
{"hook_event_name":"SessionStart","session_id":"codex-enriched","cwd":"/home/admin/src/demo","model":"gpt-5","task":{"id":"task-1","title":"Fix runtime"},"usage":{"input_tokens":12,"output_tokens":8,"total_tokens":20},"artifact":{"kind":"diff","path":"/tmp/runtime.diff"}}
JSON
)"
[[ "$(jq -r '.status' <<<"$payload")" == RUNNING ]] || { echo "Session start did not become RUNNING: $payload" >&2; exit 1; }
[[ "$(jq -r '.task.title' <<<"$payload")" == "Fix runtime" ]] || { echo "Task enrichment was lost: $payload" >&2; exit 1; }
[[ "$(jq -r '.usage.total_tokens' <<<"$payload")" == 20 ]] || { echo "Usage enrichment was lost: $payload" >&2; exit 1; }
[[ "$(jq -r '.artifact.path' <<<"$payload")" == /tmp/runtime.diff ]] || { echo "Artifact enrichment was lost: $payload" >&2; exit 1; }

payload="$(event codex <<'JSON'
{"hook_event_name":"PermissionRequest","session_id":"codex-s1","cwd":"/home/admin/src/demo","tool_name":"terminal.exec","tool_input":{"command":"sudo pacman -Syu"}}
JSON
)"
[[ "$(jq -r '.kind' <<<"$payload")" == approval.requested ]] || { echo "Codex approval event was not normalized: $payload" >&2; exit 1; }
[[ "$(jq -r '.status' <<<"$payload")" == WAITING ]] || { echo "Codex approval status was not WAITING: $payload" >&2; exit 1; }
[[ "$(jq -r '.approval.kind' <<<"$payload")" == terminal.exec ]] || { echo "Codex approval kind was not preserved: $payload" >&2; exit 1; }
[[ "$(jq -r '.approval.reason' <<<"$payload")" == 'Approval requested by Codex' ]] || { echo "Approval reason was not bounded: $payload" >&2; exit 1; }

request_id="$(event codex <<'JSON' | jq -r '.approval.id'
{"hook_event_name":"PermissionRequest","session_id":"codex-s1","cwd":"/home/admin/src/demo","tool_name":"terminal.exec","tool_call_id":"call-1"}
JSON
)"
resolved_id="$(event codex <<'JSON' | jq -r '.approval.id'
{"hook_event_name":"PermissionDenied","session_id":"codex-s1","cwd":"/home/admin/src/demo","tool_name":"terminal.exec","tool_call_id":"call-1"}
JSON
)"
[[ "$request_id" == "$resolved_id" ]] || { echo 'Approval resolution did not correlate to its request.' >&2; exit 1; }

payload="$(event hermes <<'JSON'
{"hook_event_name":"post_tool_call","session_id":"hermes-s1","cwd":"/home/admin/src/demo","tool_name":"terminal","status":"error","model":"qwen"}
JSON
)"
[[ "$(jq -r '.kind' <<<"$payload")" == tool.failed ]] || { echo "Hermes tool failure was not normalized: $payload" >&2; exit 1; }
[[ "$(jq -r '.status' <<<"$payload")" == FAILED ]] || { echo "Hermes tool failure status was not FAILED: $payload" >&2; exit 1; }

payload="$(event herdr <<'JSON'
{"hook_event_name":"FileChanged","session_id":"herdr-s1","cwd":"/home/admin/src/demo","file_path":"main.go"}
JSON
)"
[[ "$(jq -r '.kind' <<<"$payload")" == file.changed ]] || { echo "Herdr file event was not normalized: $payload" >&2; exit 1; }
[[ "$(jq -r '.file_change.path' <<<"$payload")" == main.go ]] || { echo "Herdr file path was not preserved: $payload" >&2; exit 1; }

payload="$(event herdr <<'JSON'
{"hook_event_name":"FileChanged","session_id":"herdr-s2","file_path":"main.go","operation":"modified","before":"old content","after":"new content"}
JSON
)"
before_digest="$(printf '%s' 'old content' | sha256sum | awk '{print "sha256:" $1 ";bytes:11"}')"
after_digest="$(printf '%s' 'new content' | sha256sum | awk '{print "sha256:" $1 ";bytes:11"}')"
[[ "$(jq -r '.file_change.operation' <<<"$payload")" == modified ]] || { echo "File operation was not preserved: $payload" >&2; exit 1; }
[[ "$(jq -r '.file_change.before' <<<"$payload")" == "$before_digest" ]] || { echo "Before metadata was not normalized: $payload" >&2; exit 1; }
[[ "$(jq -r '.file_change.after' <<<"$payload")" == "$after_digest" ]] || { echo "After metadata was not normalized: $payload" >&2; exit 1; }
[[ "$payload" != *'old content'* && "$payload" != *'new content'* ]] || { echo 'Raw file content leaked into the event.' >&2; exit 1; }

payload="$(event codex <<'JSON'
{"hook_event_name":"FileChanged","session_id":"codex-s2","old_path":"old.go","new_path":"main.go"}
JSON
)"
[[ "$(jq -r '.file_change.operation' <<<"$payload")" == renamed ]] || { echo "Rename operation was not inferred: $payload" >&2; exit 1; }
[[ "$(jq -r '.file_change.before' <<<"$payload")" == path:old.go ]] || { echo "Previous path metadata was not preserved: $payload" >&2; exit 1; }
[[ "$(jq -r '.file_change.after' <<<"$payload")" == path:main.go ]] || { echo "New path metadata was not preserved: $payload" >&2; exit 1; }

payload="$(event claude <<'JSON'
{"hook_event_name":"PostToolUse","session_id":"claude-s2","tool_name":"Edit","tool_input":{"file_path":"main.go","old_string":"before","new_string":"after"}}
JSON
)"
[[ "$(jq -r '.file_change.path' <<<"$payload")" == main.go ]] || { echo "Edit file path was not inferred: $payload" >&2; exit 1; }
[[ "$(jq -r '.file_change.operation' <<<"$payload")" == modified ]] || { echo "Edit operation was not inferred: $payload" >&2; exit 1; }
[[ "$(jq -r '.file_change.before' <<<"$payload")" != before && "$(jq -r '.file_change.after' <<<"$payload")" != after ]] || { echo 'Raw edit content leaked into the event.' >&2; exit 1; }

python3 - <<'PY'
import importlib.util
import json
import threading
from pathlib import Path
from unittest.mock import patch

path = Path('agentos-hermes-plugin/__init__.py')
spec = importlib.util.spec_from_file_location('agentos_hermes_plugin', path)
plugin = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(plugin)

captured = {}
ready = threading.Event()

def fake_run(*args, input, **kwargs):
    captured['args'] = args[0]
    captured['payload'] = json.loads(input)
    ready.set()

with patch.object(plugin.subprocess, 'run', fake_run), patch.object(
    plugin, 'native_event_command', return_value='/usr/bin/agentos-native-event'
):
    plugin.post_tool_call(
        session_id='hermes-s2',
        tool_name='edit',
        task={'id': 'task-2', 'title': 'Enrich Hermes event'},
        usage={'input_tokens': 12, 'output_tokens': 8, 'total_tokens': 20},
        artifact={'kind': 'diff', 'path': '/tmp/hermes.diff'},
        approval_reason='needs review',
        file_path='main.go',
        operation='modified',
        old_string='before',
        new_string='after',
    )

assert ready.wait(1), 'Hermes plugin did not forward the event'
assert captured['payload']['file_path'] == 'main.go'
assert captured['payload']['operation'] == 'modified'
assert captured['payload']['before'] == 'before'
assert captured['payload']['after'] == 'after'
assert captured['args'][0] == '/usr/bin/agentos-native-event'
assert captured['payload']['task_id'] == 'task-2'
assert captured['payload']['task_title'] == 'Enrich Hermes event'
assert captured['payload']['total_tokens'] == 20
assert captured['payload']['artifact_path'] == '/tmp/hermes.diff'
assert captured['payload']['approval_reason'] == 'needs review'
with patch.object(plugin.os, 'access', return_value=True):
    assert plugin.native_event_command() == '/usr/bin/agentos-native-event'
PY

echo 'Native event normalization passed.'
