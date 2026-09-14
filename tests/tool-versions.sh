#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

[[ -f release/tool-versions.json ]] || { echo 'release/tool-versions.json is missing' >&2; exit 1; }

jq -e '.schema == "agentos.tools/v1"' release/tool-versions.json >/dev/null

expected_tools=(claude-code codex qwen-code playwright-cli hermes herdr opencode ollama-models)
for tool in "${expected_tools[@]}"; do
  jq -e --arg t "$tool" '.tools[$t] != null' release/tool-versions.json >/dev/null || {
    echo "release/tool-versions.json is missing tool: $tool" >&2
    exit 1
  }
done

jq -e '
  .tools | to_entries | all(.[]; (.value.version // "") != "" or ((.value.models // []) | length > 0))
' release/tool-versions.json >/dev/null

jq -e '.tools | to_entries | all(.[]; .value.installer == "script" or .value.installer == "npm" or .value.installer == "ollama")' \
  release/tool-versions.json >/dev/null

grep -Fq 'tool_pin claude-code' install-agent-tools.sh
grep -Fq 'tool_pin hermes' install-agent-tools.sh
grep -Fq 'tool_pin herdr' install-agent-tools.sh
grep -Fq 'tool_pin opencode' install-agent-tools.sh
grep -Fq 'tool_pin codex' install-agent-tools.sh
grep -Fq 'bash -s "$pinned_version"' install-agent-tools.sh
! grep -Fq 'tool_pin codex' update-workstation.sh
grep -Fq 'tool_pin qwen-code' update-workstation.sh
grep -Fq 'tool_pin playwright-cli' update-workstation.sh
grep -Fq 'ollama-models' update-workstation.sh

[[ -x release/query-tool-versions.sh ]] || { echo 'release/query-tool-versions.sh must be executable' >&2; exit 1; }
bash -n release/query-tool-versions.sh
grep -Fq 'npm view' release/query-tool-versions.sh
grep -Fq 'ollama-models' release/query-tool-versions.sh || true

[[ -f .github/workflows/tool-bump.yml ]] || { echo '.github/workflows/tool-bump.yml is missing' >&2; exit 1; }
grep -Fq 'schedule:' .github/workflows/tool-bump.yml
grep -Fq 'query-tool-versions.sh' .github/workflows/tool-bump.yml
grep -Fq 'create-pull-request' .github/workflows/tool-bump.yml
grep -Fq 'pull-requests: write' .github/workflows/tool-bump.yml
! grep -Fiq 'auto-merge' .github/workflows/tool-bump.yml
! grep -Fiq 'automerge' .github/workflows/tool-bump.yml

echo 'Tool version pinning validation passed.'
