#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURRENT="${1:-$ROOT/release/tool-versions.json}"
[[ -f "$CURRENT" ]] || { echo "tool versions file not found: $CURRENT" >&2; exit 1; }

npm_version() {
  npm view "$1" version
}

github_branch_head() {
  curl -fsSL "https://api.github.com/repos/$1/branches/$2" | jq -er '.commit.sha'
}

herdr_version() {
  curl -fsSL https://herdr.dev/latest.json | jq -er '.version'
}

opencode_version() {
  curl -fsSL https://api.github.com/repos/anomalyco/opencode/releases/latest \
    | jq -er '.tag_name | ltrimstr("v")'
}

claude_version="$(npm_version @anthropic-ai/claude-code)"
codex_version="$(npm_version @openai/codex)"
qwen_version="$(npm_version @qwen-code/qwen-code)"
playwright_version="$(npm_version @playwright/cli)"
hermes_version="$(github_branch_head NousResearch/hermes-agent main)"
herdr_version="$(herdr_version)"
opencode_version="$(opencode_version)"

# ollama-models is a curated list of model tags, not an upstream release with
# a latest version. It is updated manually, not by this script.
jq \
  --arg claude "$claude_version" \
  --arg codex "$codex_version" \
  --arg qwen "$qwen_version" \
  --arg playwright "$playwright_version" \
  --arg hermes "$hermes_version" \
  --arg herdr "$herdr_version" \
  --arg opencode "$opencode_version" \
  '.tools["claude-code"].version = $claude
   | .tools["codex"].version = $codex
   | .tools["qwen-code"].version = $qwen
   | .tools["playwright-cli"].version = $playwright
   | .tools["hermes"].version = $hermes
   | .tools["herdr"].version = $herdr
   | .tools["opencode"].version = $opencode' \
  "$CURRENT"
