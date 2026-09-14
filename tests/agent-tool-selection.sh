#!/usr/bin/env bash
set -euo pipefail
if (( EUID == 0 )); then
  exec runuser -u nobody -- bash "$0"
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home/.local/bin" "$tmp/skills/agentos-operator"
fake_bin="$tmp/home/.local/bin"
printf 'test skill\n' > "$tmp/skills/agentos-operator/SKILL.md"
pin="$(jq -r '.tools.codex.version' "$repo_root/release/tool-versions.json")"
printf '#!/bin/sh\nprintf "codex-cli %s\\n"\n' "$pin" > "$fake_bin/codex"
printf '#!/bin/sh\necho "unexpected npm install" >&2\nexit 99\n' > "$fake_bin/npm"
printf '#!/bin/sh\nexit 0\n' > "$fake_bin/agentos-native-event"
chmod +x "$fake_bin/"*
export HOME="$tmp/home" PATH="$fake_bin:$PATH"
export AGENTOS_TOOL_VERSIONS_FILE="$repo_root/release/tool-versions.json"
export AGENTOS_SKILLS_SOURCE="$tmp/skills"
export SELECTION_LOG="$tmp/selected.log"
bash -c '
  script="$1"
  set -- --agent codex --opencode --ide vscode
  source "$script"
  install_opencode() { echo opencode >> "$SELECTION_LOG"; }
  install_ide() { [[ "$IDE" == vscode ]]; echo vscode >> "$SELECTION_LOG"; }
  main
' bash "$repo_root/install-agent-tools.sh"
grep -Fxq opencode "$SELECTION_LOG"
grep -Fxq vscode "$SELECTION_LOG"
test -L "$HOME/.agents/skills/agentos-operator"
test -f "$HOME/.codex/hooks.json"
grep -Fxq 'hooks = true' "$HOME/.codex/config.toml"
test ! -e "$HOME/.claude"
test ! -e "$HOME/.hermes"
mkdir "$tmp/empty-home"
HOME="$tmp/empty-home" bash -c '
  script="$1"
  set -- --agents "" --ide vscode
  source "$script"
  install_ide() { [[ "$IDE" == vscode ]]; echo empty-vscode >> "$SELECTION_LOG"; }
  main
' bash "$repo_root/install-agent-tools.sh"
grep -Fxq empty-vscode "$SELECTION_LOG"
test ! -e "$tmp/empty-home/.codex"
echo 'Agent selection, pinned Codex rerun, optional tooling, and selected integration passed.'
