#!/usr/bin/env bash
set -euo pipefail
if (( EUID == 0 )); then
  exec runuser -u nobody -- bash "$0"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$repo_root/install-agent-tools.sh" --help | grep -Fq -- '--opencode'
bash "$repo_root/install-agent-tools.sh" --help | grep -Fq -- '--agent AGENT'
bash "$repo_root/install-agent-tools.sh" --agents codex,codex --help | grep -Fq 'Usage:'
bash "$repo_root/install-agent-tools.sh" --agent codex --agent codex --help | grep -Fq 'Usage:'
bash "$repo_root/install.sh" --help | grep -Fq -- '--ide IDE'
bash "$repo_root/update-workstation.sh" --help | grep -Fq -- '--ide IDE'
if bash "$repo_root/sync-workstation.sh" --opencode --ide vscode --bad >/dev/null 2>&1; then
  echo 'sync-workstation accepted an unknown option' >&2
  exit 1
fi

if bash "$repo_root/install-agent-tools.sh" --ide invalid >/tmp/agentos-invalid-ide.out 2>&1; then
  echo 'install-agent-tools accepted an invalid IDE' >&2
  exit 1
fi
grep -Fq 'Unsupported IDE: invalid' /tmp/agentos-invalid-ide.out
rm -f /tmp/agentos-invalid-ide.out

grep -Fq 'AGENTOS_INSTALL_OPENCODE="$INSTALL_OPENCODE" AGENTOS_IDE="$IDE"' "$repo_root/install.sh"
grep -Fq 'AGENTOS_INSTALL_OPENCODE=$INSTALL_OPENCODE' "$repo_root/bootstrap.sh"
grep -Fq 'TOOLING_CONFIG=' "$repo_root/sync-workstation.sh"
grep -Fq '[[ "$IDE" == cursor ]] || return 0' "$repo_root/update-workstation.sh"
grep -Fq 'AgentOS essentials only' "$repo_root/install.sh"
grep -Fq 'Use arrow keys and Enter.' "$repo_root/install.sh"
grep -Fq 'npm install --global --prefix "$HOME/.local" "@openai/codex@' "$repo_root/install-agent-tools.sh"
! grep -Fq '"@openai/codex@${codex_version}"' "$repo_root/update-workstation.sh"
grep -Fq '"@qwen-code/qwen-code@${qwen_version}"' "$repo_root/update-workstation.sh"
grep -Fq '"@playwright/cli@${playwright_version}"' "$repo_root/update-workstation.sh"

tmp_install_test="$(mktemp -d)"
trap 'rm -rf "$tmp_install_test"' EXIT
mkdir -p "$tmp_install_test/home/.local/bin"
cat > "$tmp_install_test/tool-versions.json" <<'EOF'
{"tools":{"codex":{"version":"0.153.4"},"opencode":{"version":"1.18.28"}}}
EOF
cat > "$tmp_install_test/home/.local/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex-cli 0.153.4\n'
EOF
cat > "$tmp_install_test/home/.local/bin/opencode" <<'EOF'
#!/usr/bin/env bash
printf '1.18.28\n'
EOF
cat > "$tmp_install_test/home/.local/bin/code" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$tmp_install_test/home/.local/bin/npm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CODEX_NPM_LOG:?}"
EOF
chmod 700 "$tmp_install_test/home/.local/bin/"*

install_output="$tmp_install_test/install.out"
HOME="$tmp_install_test/home" \
PATH="$tmp_install_test/home/.local/bin:$PATH" \
AGENTOS_TOOL_VERSIONS_FILE="$tmp_install_test/tool-versions.json" \
CODEX_NPM_LOG="$tmp_install_test/npm.log" \
  bash "$repo_root/install-agent-tools.sh" --agent codex --opencode --ide vscode >"$install_output" 2>&1
[[ ! -s "$tmp_install_test/npm.log" ]] || {
  echo 'Pinned Codex rerun invoked npm despite codex-cli version output matching the pin.' >&2
  exit 1
}
grep -Fq '==> OpenCode (optional)' "$install_output"
grep -Fq '==> IDE: vscode' "$install_output"
! grep -Fq '==> Claude Code' "$install_output"
! grep -Fq '==> Hermes Agent' "$install_output"
! grep -Fq '==> Herdr agent multiplexer' "$install_output"

echo 'Optional tool option validation passed.'
