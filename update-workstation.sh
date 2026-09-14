#!/usr/bin/env bash
set -euo pipefail

WORKSTATION_USER="${WORKSTATION_USER:-${SUDO_USER:-}}"
INSTALL_OPENCODE="${AGENTOS_INSTALL_OPENCODE:-0}"
IDE="${AGENTOS_IDE:-none}"

TOOL_VERSIONS_FILE="${AGENTOS_TOOL_VERSIONS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release/tool-versions.json}"

tool_pin() {
  local tool="$1" field="${2:-version}"
  jq -er --arg t "$tool" --arg f "$field" '.tools[$t][$f]' "$TOOL_VERSIONS_FILE"
}

usage() {
  cat <<'EOF'
Usage: update-workstation [--opencode] [--ide IDE]

Optional IDE values: none, cursor, vscode, webstorm.
EOF
}

while (($# > 0)); do
  case "$1" in
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
if [[ -z "$WORKSTATION_USER" ]]; then
  WORKSTATION_USER="$(getent group wheel | awk -F: '{ split($4, users, ","); print users[1] }')"
fi

step() {
  printf '\n==> %s\n' "$1"
}

run() {
  printf '+ %s\n' "$*"
  "$@"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo 'Run update-workstation as root (normally: sudo update-workstation).' >&2
    exit 1
  fi
}

update_pacman() {
  step 'Pacman system update'
  run pacman -Syu --noconfirm
}

update_node_tools() {
  if ! have npm; then
    step 'Node tooling'
    echo 'npm not found, skipping Qwen Code and Playwright CLI updates.'
    return
  fi

  step 'Node tooling'
  local qwen_version playwright_version
  qwen_version="$(tool_pin qwen-code)"
  playwright_version="$(tool_pin playwright-cli)"
  # npm 12 blocks lifecycle scripts unless explicitly approved. Qwen Code's
  # optional audio-capture dependency uses an install script, so allow only that
  # package rather than disabling npm's lifecycle-script protection globally.
  run npm install -g \
    --allow-scripts=@qwen-code/audio-capture \
    "@qwen-code/qwen-code@${qwen_version}" \
    "@playwright/cli@${playwright_version}"
}

update_user_agent_tools() {
  step 'User agent tooling'
  if [[ -z "$WORKSTATION_USER" || "$WORKSTATION_USER" == root ]]; then
    echo 'Cannot resolve the workstation user; skipping Claude Code, Hermes, and user browser updates.'
    return
  fi

  local installer=/usr/bin/install-agent-tools
  [[ -x "$installer" ]] || installer=/usr/local/bin/install-agent-tools
  if [[ ! -x "$installer" ]]; then
    echo 'install-agent-tools is not installed; skipping user-scoped agent updates.'
    return
  fi

  local home_dir user_shell
  home_dir="$(getent passwd "$WORKSTATION_USER" | cut -d: -f6)"
  user_shell="$(getent passwd "$WORKSTATION_USER" | cut -d: -f7)"
  if [[ -z "$home_dir" || ! -d "$home_dir" ]]; then
    echo "Cannot resolve home directory for $WORKSTATION_USER; skipping user agent updates." >&2
    return
  fi

  local optional_args=(--update)
  (( INSTALL_OPENCODE )) && optional_args+=(--opencode)
  [[ "$IDE" == none ]] || optional_args+=(--ide "$IDE")
  run runuser -u "$WORKSTATION_USER" -- env \
    HOME="$home_dir" \
    USER="$WORKSTATION_USER" \
    SHELL="${user_shell:-/bin/zsh}" \
    PATH="$home_dir/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    "$installer" "${optional_args[@]}"
}

update_ollama_models() {
  if ! have ollama; then
    step 'Ollama models'
    echo 'ollama not found, skipping model pull.'
    return
  fi

  step 'Ollama models'
  # Agent fallback needs a tool-calling-capable local model; gemma4 lacks a
  # solid tool template. The model list lives in release/tool-versions.json,
  # so a pin bump only touches one file.
  local model
  while IFS= read -r model; do
    run ollama pull "$model"
  done < <(jq -er '.tools["ollama-models"].models[]' "$TOOL_VERSIONS_FILE")
}

update_cursor() {
  [[ "$IDE" == cursor ]] || return 0
  step 'Cursor editor'
  if pacman -Qi cursor-bin >/dev/null 2>&1; then
    if have paru; then
      run paru -Syu --noconfirm cursor-bin
    elif have yay; then
      run yay -Syu --noconfirm cursor-bin
    else
      echo 'cursor-bin is installed, but no AUR helper was found to update it.'
    fi
    return
  fi

  if have paru; then
    run paru -S --noconfirm cursor-bin
  elif have yay; then
    run yay -S --noconfirm cursor-bin
  else
    echo 'No AUR helper found. Install cursor-bin manually if you want Cursor on this machine.'
  fi
}

main() {
  need_root
  update_pacman
  update_node_tools
  update_user_agent_tools
  update_ollama_models
  update_cursor
  step 'Done'
  echo 'Workstation update completed.'
}

main "$@"
