#!/usr/bin/env bash
# Install and maintain user-scoped agent tooling after the base workstation exists.
set -euo pipefail

MODE=install
INSTALL_OPENCODE="${AGENTOS_INSTALL_OPENCODE:-0}"
IDE="${AGENTOS_IDE:-none}"
REQUESTED_AGENTS=()
AGENTS_SPECIFIED=0

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${AGENTOS_TOOL_VERSIONS_FILE:-}" ]]; then
  TOOL_VERSIONS_FILE="$AGENTOS_TOOL_VERSIONS_FILE"
elif [[ -f /usr/share/agentos/tool-versions.json ]]; then
  TOOL_VERSIONS_FILE=/usr/share/agentos/tool-versions.json
else
  TOOL_VERSIONS_FILE="$script_dir/release/tool-versions.json"
fi

tool_pin() {
  local tool="$1" field="${2:-version}"
  jq -er --arg t "$tool" --arg f "$field" '.tools[$t][$f]' "$TOOL_VERSIONS_FILE"
}

first_version_token() {
  awk '{print $1}' | sed -E 's/^[vV]//'
}

install_codex() {
  step 'Codex'
  install -d -m 700 "$HOME/.local" "$HOME/.local/bin"

  require_command npm
  local pinned_version
  pinned_version="$(tool_pin codex)"
  if command -v codex >/dev/null 2>&1; then
    local current_version
    current_version="$(codex --version | awk '{print $NF}' | first_version_token)"
    if [[ "$current_version" == "$pinned_version" && "$MODE" != --update ]]; then
      codex --version
      return
    fi
  fi

  npm install --global --prefix "$HOME/.local" "@openai/codex@${pinned_version}"
  export PATH="$HOME/.local/bin:$PATH"
  hash -r
  require_command codex
  codex --version
}

usage() {
  cat <<'EOF'
Usage: install-agent-tools [--update] [--agent AGENT]... [--agents LIST] [--opencode] [--ide IDE]

AGENT values: claude, codex, hermes, herdr. Without --agent/--agents, all
four core agents are installed for backwards compatibility. An empty
--agents value installs no agents.
Optional IDE values: none, cursor, vscode, webstorm.
Optional tools are not installed unless explicitly selected.
EOF
}

agent_requested() {
  (( AGENTS_SPECIFIED )) || return 0
  local agent
  for agent in "${REQUESTED_AGENTS[@]}"; do
    [[ "$agent" != "$1" ]] || return 0
  done
  return 1
}

add_requested_agents() {
  local csv="$1" agent existing
  IFS=',' read -r -a parsed <<< "$csv"
  for agent in "${parsed[@]}"; do
    [[ -z "$agent" ]] && continue
    case "$agent" in claude|codex|hermes|herdr) ;; *)
      echo "Unsupported agent: $agent" >&2
      usage >&2
      exit 2
      ;;
    esac
    existing=0
    for selected in "${REQUESTED_AGENTS[@]}"; do
      [[ "$selected" == "$agent" ]] && existing=1
    done
    if (( existing == 0 )); then
      REQUESTED_AGENTS+=("$agent")
    fi
  done
}

while (($# > 0)); do
  case "$1" in
    --update) MODE=--update ;;
    --agent)
      (($# >= 2)) || { echo '--agent needs a value' >&2; usage >&2; exit 2; }
      AGENTS_SPECIFIED=1
      add_requested_agents "$2"
      shift
      ;;
    --agents)
      (($# >= 2)) || { echo '--agents needs a value' >&2; usage >&2; exit 2; }
      AGENTS_SPECIFIED=1
      add_requested_agents "$2"
      shift
      ;;
    --opencode) INSTALL_OPENCODE=1 ;;
    --ide)
      (($# >= 2)) || { echo '--ide needs a value' >&2; usage >&2; exit 2; }
      IDE="$2"
      shift
      ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$INSTALL_OPENCODE" == 0 || "$INSTALL_OPENCODE" == 1 ]] || {
  echo 'AGENTOS_INSTALL_OPENCODE must be 0 or 1.' >&2
  exit 2
}
case "$IDE" in
  none|cursor|vscode|webstorm) ;;
  *) echo "Unsupported IDE: $IDE" >&2; usage >&2; exit 2 ;;
esac

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
AGENT_BROWSER_PROFILE="${AGENT_BROWSER_PROFILE:-$HOME/.local/share/agent-browser}"

if [[ -z "${AGENT_BROWSER_EXECUTABLE_PATH:-}" ]] && command -v chromium >/dev/null 2>&1; then
  export AGENT_BROWSER_EXECUTABLE_PATH="$(command -v chromium)"
fi
if [[ -n "${AGENT_BROWSER_EXECUTABLE_PATH:-}" ]]; then
  export PLAYWRIGHT_MCP_EXECUTABLE_PATH="$AGENT_BROWSER_EXECUTABLE_PATH"
fi

step() {
  printf '\n==> %s\n' "$1"
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Required command is still missing after install: $name" >&2
    return 1
  fi
}

install_claude() {
  step 'Claude Code'
  install -d -m 700 "$HOME/.local" "$HOME/.local/bin"

  local pinned_version
  pinned_version="$(tool_pin claude-code)"

  if command -v claude >/dev/null 2>&1; then
    local current_version
    current_version="$(claude --version | first_version_token)"
    if [[ "$current_version" == "$pinned_version" ]]; then
      claude --version
      return
    fi
    echo "Claude Code $current_version is installed; release/tool-versions.json pins $pinned_version. Reinstalling the pinned version."
  fi

  # Clean leftovers from failed npm/native attempts before using Anthropic's
  # recommended native Linux installer. Never delete an unexpected directory.
  local claude_path="$HOME/.local/bin/claude"
  if [[ -L "$claude_path" || -f "$claude_path" ]]; then
    echo "Removing stale Claude launcher: $claude_path"
    rm -f "$claude_path"
  elif [[ -e "$claude_path" ]]; then
    echo "Cannot replace $claude_path because it is not a regular file or symlink." >&2
    return 1
  fi

  rm -rf "$HOME/.local/share/claude"
  curl -fsSL https://claude.ai/install.sh | bash -s "$pinned_version"

  export PATH="$HOME/.local/bin:$PATH"
  hash -r
  require_command claude
  local installed_version
  installed_version="$(claude --version | first_version_token)"
  if [[ "$installed_version" != "$pinned_version" ]]; then
    echo "Claude Code installer landed on $installed_version instead of pinned $pinned_version; recording the version that actually landed." >&2
  fi
  claude --version
}

install_hermes() {
  step 'Hermes Agent'
  install -d -m 700 "$HOME/.local/bin"

  local pinned_version
  pinned_version="$(tool_pin hermes)"

  if command -v hermes >/dev/null 2>&1; then
    if [[ "$MODE" == --update ]]; then
      curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
        | bash -s -- --skip-browser --skip-setup --commit "$pinned_version"
    fi
  else
    # Browser automation is provisioned separately with Arch Chromium. Skip the
    # Hermes Playwright/browser stage so its installer cannot stall on a browser
    # download or request package-manager sudo from an unprivileged shell.
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
      | bash -s -- --skip-browser --skip-setup --commit "$pinned_version"
  fi

  export PATH="$HOME/.local/bin:$PATH"
  hash -r
  require_command hermes
  echo "Hermes is pinned to commit $pinned_version."
  hermes --version
}

install_herdr() {
  step 'Herdr agent multiplexer'

  install -d -m 700 \
    "$HOME/.local/bin" \
    "$HOME/.config/herdr" \
    "$HOME/.zfunc" \
    "$HOME/.claude" \
    "$HOME/.codex"

  # Herdr's official installer verifies the release SHA-256 and installs to
  # ~/.local/bin when HERDR_INSTALL_DIR is set. Do not replace the binary while
  # a Herdr server is alive: a protocol-changing release could make the new
  # client incompatible with long-running panes. The next sync with no running
  # Herdr server will update it.
  local should_install=1
  if command -v herdr >/dev/null 2>&1; then
    if herdr status server >/dev/null 2>&1; then
      should_install=0
      echo 'Herdr server is running; keeping the current binary to avoid disrupting active agent panes.'
    fi
  fi

  if (( should_install )); then
    curl -fsSL https://herdr.dev/install.sh \
      | env HERDR_INSTALL_DIR="$HOME/.local/bin" sh
  fi

  export PATH="$HOME/.local/bin:$PATH"
  hash -r
  require_command herdr
  local pinned_version installed_version
  pinned_version="$(tool_pin herdr)"
  installed_version="$(herdr --version | first_version_token)"
  if [[ "$installed_version" != "$pinned_version" ]]; then
    echo "Herdr has no version-pinning installer option; recorded version $installed_version (release/tool-versions.json lists $pinned_version)." >&2
  fi
  herdr --version

  # Scripted workstation convergence replaces Herdr's first-run wizard. Keep
  # this minimal and preserve every other user customization in config.toml.
  local config="$HOME/.config/herdr/config.toml"
  local config_tmp="$HOME/.config/herdr/.config.toml.$$"
  if [[ -f "$config" ]]; then
    if grep -qE '^[[:space:]]*onboarding[[:space:]]*=' "$config"; then
      sed -E 's/^[[:space:]]*onboarding[[:space:]]*=.*/onboarding = false/' "$config" > "$config_tmp"
    else
      {
        echo 'onboarding = false'
        cat "$config"
      } > "$config_tmp"
    fi
    mv "$config_tmp" "$config"
  else
    printf 'onboarding = false\n' > "$config"
  fi
  chmod 600 "$config"

  # Native Herdr integrations provide agent session identity/lifecycle data.
  # Claude and Codex directories are created above so their hooks can be
  # installed before first use. Hermes is only integrated once it has a real
  # ~/.hermes configuration, avoiding interference with Hermes' own setup flow.
  herdr integration install claude
  herdr integration install codex
  if [[ -d "$HOME/.hermes" ]]; then
    herdr integration install hermes
  else
    echo 'Hermes is not configured yet; Herdr Hermes integration will be installed after Hermes setup/import.'
  fi

  # Install zsh completion. dotfiles/.zshrc adds ~/.zfunc to fpath before compinit.
  herdr completion zsh > "$HOME/.zfunc/_herdr"
  chmod 600 "$HOME/.zfunc/_herdr"

  echo 'Herdr integrations:'
  herdr integration status || true
}

install_agentos_skills() {
  step 'AgentOS skills'
  local source="${AGENTOS_SKILLS_SOURCE:-/usr/share/agentos/skills}"
  if [[ ! -d "$source" ]]; then
    echo "AgentOS skill source is not installed: $source" >&2
    return 0
  fi
  source="$(cd "$source" && pwd)"

  local target_root skill_file skill_name target existing
  local targets=()
  if agent_requested codex; then targets+=("$HOME/.agents/skills"); fi
  if agent_requested claude; then targets+=("$HOME/.claude/skills"); fi
  if agent_requested hermes; then targets+=("$HOME/.hermes/skills"); fi
  for target_root in "${targets[@]}"; do
    install -d -m 700 "$target_root"
    for skill_file in "$source"/*/SKILL.md; do
      [[ -f "$skill_file" ]] || continue
      skill_name="$(basename "$(dirname "$skill_file")")"
      target="$target_root/$skill_name"
      if [[ -L "$target" ]]; then
        existing="$(readlink "$target")"
        if [[ "$existing" == "$source/$skill_name" ]]; then
          echo "Preserving AgentOS skill link: $target"
        else
          echo "Preserving existing skill link: $target -> $existing" >&2
        fi
      elif [[ -e "$target" ]]; then
        echo "Preserving existing skill: $target" >&2
      else
        ln -s "$source/$skill_name" "$target"
        echo "Installed AgentOS skill link: $target -> $source/$skill_name"
      fi
    done
  done
}

install_opencode() {
  step 'OpenCode (optional)'
  local pinned_version installed_version
  pinned_version="$(tool_pin opencode)"

  if command -v opencode >/dev/null 2>&1; then
    installed_version="$(opencode --version | first_version_token)"
    if [[ "$installed_version" != "$pinned_version" ]]; then
      echo "OpenCode $installed_version is installed; release/tool-versions.json pins $pinned_version. Reinstalling the pinned version."
    else
      opencode --version
      return
    fi
  fi

  # OpenCode's official installer supports XDG_BIN_DIR and installs only in
  # the user's home. Keep the optional tool out of the signed system package.
  XDG_BIN_DIR="$HOME/.local/bin" curl -fsSL https://opencode.ai/install | bash -s -- --version "$pinned_version"
  export PATH="$HOME/.local/bin:$PATH"
  hash -r
  require_command opencode
  installed_version="$(opencode --version | first_version_token)"
  if [[ "$installed_version" != "$pinned_version" ]]; then
    echo "OpenCode installer landed on $installed_version instead of pinned $pinned_version." >&2
  fi
  opencode --version
}

install_aur_package() {
  local package="$1" command_name="$2" helper=''
  if command -v "$command_name" >/dev/null 2>&1; then
    "$command_name" --version 2>/dev/null || true
    return
  fi
  if command -v paru >/dev/null 2>&1; then
    helper=paru
  elif command -v yay >/dev/null 2>&1; then
    helper=yay
  else
    echo "${package} was selected, but neither paru nor yay is installed." >&2
    echo "Install an AUR helper first, then rerun: install-agent-tools --ide ${IDE}" >&2
    return 1
  fi
  "$helper" -S --needed --noconfirm "$package"
  require_command "$command_name"
}

install_ide() {
  [[ "$IDE" != none ]] || return 0
  step "IDE: $IDE"
  case "$IDE" in
    vscode)
      if ! command -v code >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm code
      fi
      require_command code
      ;;
    cursor) install_aur_package cursor-bin cursor ;;
    webstorm) install_aur_package webstorm webstorm ;;
  esac
}

install_native_hooks() {
  step 'AgentOS native event hooks'
  local command_path
  if [[ -x /usr/bin/agentos-native-event ]]; then
    command_path=/usr/bin/agentos-native-event
  else
    command_path="$(command -v agentos-native-event || true)"
  fi
  if [[ -z "$command_path" ]]; then
    echo 'agentos-native-event is not installed; skipping native hook wiring.' >&2
    return 0
  fi

  # Claude Code and Codex intentionally share the documented hook envelope.
  # Merge only our exact command into existing settings so user hooks survive.
  merge_json_hooks() {
    local settings="$1"
    [[ -f "$settings" ]] || printf '{"hooks":{}}\n' > "$settings"
    python3 - "$settings" "$command_path" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
command = sys.argv[2]
events = (
    "SessionStart", "SessionEnd", "PreToolUse", "PermissionRequest",
    "PermissionDenied", "PostToolUse", "PostToolUseFailure", "Stop",
    "TaskCreated", "TaskCompleted",
)

try:
    data = json.loads(path.read_text())
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"Cannot merge native hooks into {path}: {exc}")

hooks = data.setdefault("hooks", {})
for event in events:
    groups = hooks.setdefault(event, [])
    group = next((item for item in groups if item.get("matcher") == "*"), None)
    if group is None:
        group = {"matcher": "*", "hooks": []}
        groups.append(group)
    handlers = group.setdefault("hooks", [])
    if not any(item.get("type") == "command" and item.get("command") == command for item in handlers):
        handler = {"type": "command", "command": command, "args": ["--agent", "PLACEHOLDER"]}
        handlers.append(handler)

agent = "codex" if ".codex" in str(path) else "claude"
for event in events:
    for group in hooks[event]:
        for handler in group.get("hooks", []):
            if handler.get("command") == command:
                handler["args"] = ["--agent", agent]
                handler["async"] = event != "SessionEnd"

path.parent.mkdir(parents=True, exist_ok=True)
fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
try:
    with os.fdopen(fd, "w") as stream:
        json.dump(data, stream, indent=2)
        stream.write("\n")
    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, path)
except Exception:
    try:
        os.unlink(tmp_name)
    except FileNotFoundError:
        pass
    raise
PY
  }

  if agent_requested claude; then
    install -d -m 700 "$HOME/.claude"
    merge_json_hooks "$HOME/.claude/settings.json"
  fi

  if agent_requested codex; then
    # Codex loads hooks.json only when the lifecycle-hook feature is enabled.
    # Preserve the rest of config.toml and add/update only that boolean.
    python3 - "$HOME/.codex/config.toml" <<'PY'
from pathlib import Path
import os
import re
import sys
import tempfile

path = Path(sys.argv[1])
text = path.read_text() if path.exists() else ""
lines = text.splitlines()
for i, line in enumerate(lines):
    if re.match(r"^hooks\s*=\s*", line) and any(re.match(r"^\[features\]", x) for x in lines[:i + 1]):
        lines[i] = "hooks = true"
        break
else:
    try:
        section = next(i for i, line in enumerate(lines) if re.match(r"^\[features\]\s*$", line))
    except StopIteration:
        if lines and lines[-1] != "":
            lines.append("")
        lines.extend(["[features]", "hooks = true"])
    else:
        lines.insert(section + 1, "hooks = true")

path.parent.mkdir(parents=True, exist_ok=True)
fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
with os.fdopen(fd, "w") as stream:
    stream.write("\n".join(lines).rstrip() + "\n")
os.chmod(tmp_name, 0o600)
os.replace(tmp_name, path)
PY

    merge_json_hooks "$HOME/.codex/hooks.json"
  fi

  # Hermes plugin hooks are native to the agent loop and are enabled without
  # changing the user's YAML configuration or intercepting approvals.
  local plugin_source="${AGENTOS_HERMES_PLUGIN_SOURCE:-/usr/share/agentos/hermes-plugin}"
  if ! agent_requested hermes; then
    return 0
  elif [[ -d "$HOME/.hermes" && -d "$plugin_source" ]]; then
    local plugin_target="$HOME/.hermes/plugins/agentos-observability"
    install -d -m 700 "$HOME/.hermes/plugins" "$plugin_target"
    install -m 600 "$plugin_source/plugin.yaml" "$plugin_target/plugin.yaml"
    install -m 700 "$plugin_source/__init__.py" "$plugin_target/__init__.py"
    hermes plugins enable agentos-observability --no-allow-tool-override >/dev/null 2>&1 || \
      echo 'Hermes AgentOS plugin was installed but could not be enabled automatically.' >&2
  else
    echo 'Hermes is not configured yet; native Hermes hook installation deferred.'
  fi
}

install_browser_runtime() {
  step 'Agent browser'
  local config_dir="$HOME/.config/playwright-cli"
  local config_file="$config_dir/cli.config.json"

  install -d -m 700 "$AGENT_BROWSER_PROFILE" "$HOME/.local/bin" "$config_dir"

  if ! command -v playwright-cli >/dev/null 2>&1; then
    echo 'playwright-cli is not installed. Run sudo update-workstation first.' >&2
    return 1
  fi

  if [[ -n "${AGENT_BROWSER_EXECUTABLE_PATH:-}" ]]; then
    printf 'Using system browser: %s\n' "$AGENT_BROWSER_EXECUTABLE_PATH"
    cat > "$config_file" <<EOF
{
  "browser": {
    "browserName": "chromium",
    "isolated": false,
    "userDataDir": "$AGENT_BROWSER_PROFILE",
    "launchOptions": {
      "executablePath": "$AGENT_BROWSER_EXECUTABLE_PATH"
    }
  }
}
EOF
  else
    echo 'System Chromium was not found; installing Playwright browser fallback.' >&2
    playwright-cli install-browser
    cat > "$config_file" <<EOF
{
  "browser": {
    "browserName": "chromium",
    "isolated": false,
    "userDataDir": "$AGENT_BROWSER_PROFILE"
  }
}
EOF
  fi
  chmod 600 "$config_file"

  cat > "$HOME/.local/bin/agent-browser" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
exec playwright-cli --config "$HOME/.config/playwright-cli/cli.config.json" open "$@"
WRAPPER
  chmod 700 "$HOME/.local/bin/agent-browser"

  printf 'Persistent agent browser profile: %s\n' "$AGENT_BROWSER_PROFILE"
  echo 'Launch with: agent-browser https://example.com --headed'
}

verify_installation() {
  step 'Verify agent tooling'
  require_command claude
  require_command hermes
  require_command herdr
  require_command codex
  require_command playwright-cli
  require_command chromium
  require_command agent-browser
  if (( INSTALL_OPENCODE )); then require_command opencode; fi
  case "$IDE" in
    cursor) require_command cursor ;;
    vscode) require_command code ;;
    webstorm) require_command webstorm ;;
  esac
  echo 'Claude Code, Codex, Hermes, Herdr, Playwright CLI, Chromium, and agent-browser are available.'
  (( INSTALL_OPENCODE )) && echo 'Optional OpenCode is available.'
  [[ "$IDE" == none ]] || echo "Optional IDE is available: $IDE."
}

main() {
  if [[ ${EUID} -eq 0 ]]; then
    echo 'Run install-agent-tools as the workstation user, not root.' >&2
    return 1
  fi
  if (( AGENTS_SPECIFIED )); then
    for agent in "${REQUESTED_AGENTS[@]}"; do
      case "$agent" in
        claude) install_claude ;;
        codex) install_codex ;;
        hermes) install_hermes ;;
        herdr) install_herdr ;;
      esac
    done
  else
    install_claude
    install_codex
    install_hermes
    install_herdr
  fi
  install_agentos_skills
  (( INSTALL_OPENCODE )) && install_opencode
  install_ide
  install_native_hooks
  if (( AGENTS_SPECIFIED )); then
    step 'Done'
    echo 'Selected agent tooling is ready.'
    return 0
  fi
  install_browser_runtime
  verify_installation
  step 'Done'
  echo 'User agent tooling is ready.'
  echo 'Run `herdr` from a project directory to launch/reattach the persistent agent workspace.'
  echo 'Run hermes setup before starting a Hermes gateway if Hermes is not configured yet.'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
