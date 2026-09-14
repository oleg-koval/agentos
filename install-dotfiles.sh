#!/usr/bin/env bash
# Link the portable Linux dotfiles shipped with this workstation repository.
set -euo pipefail

USERNAME="${SUDO_USER:-${USER}}"
[[ "$USERNAME" != root ]] || { echo 'Run this as the workstation user, not root.' >&2; exit 1; }
HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
SOURCE_DIR="${DOTFILES_SOURCE:-$HOME_DIR/.local/share/agentos/dotfiles}"
if [[ ! -e "$SOURCE_DIR" && -d "$HOME_DIR/.local/share/legacy-workstation/dotfiles" ]]; then
  SOURCE_DIR="$HOME_DIR/.local/share/legacy-workstation/dotfiles"
fi
BACKUP_DIR="$HOME_DIR/.dotfiles-backups/$(date +%Y%m%d-%H%M%S)"
DOTFILES_REPO="${AGENTOS_DOTFILES_REPO:-${DOTFILES_REPO:-}}"
INSTALL_NVIM="${INSTALL_NVIM:-0}"

link_path() {
  local source="$1" target="$2"
  if [[ -L "$target" && "$(readlink -f "$target")" == "$(readlink -f "$source")" ]]; then
    return
  fi
  mkdir -p "$(dirname "$target")"
  if [[ -e "$target" || -L "$target" ]]; then
    mkdir -p "$BACKUP_DIR/$(dirname "${target#"$HOME_DIR/"}")"
    mv "$target" "$BACKUP_DIR/${target#"$HOME_DIR/"}"
  fi
  ln -s "$source" "$target"
  printf 'linked %s\n' "$target"
}

lua_single_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value=${value//\'/\\\'}
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  printf '%s' "$value"
}

ensure_dotfiles_repo_access() {
  if GIT_TERMINAL_PROMPT=0 git ls-remote "$DOTFILES_REPO" HEAD >/dev/null 2>&1; then
    return
  fi

  case "$DOTFILES_REPO" in
    https://github.com/*)
      ;;
    *)
      printf 'Cannot access %s. Authenticate Git for this remote and rerun install-dotfiles.\n' "$DOTFILES_REPO" >&2
      exit 1
      ;;
  esac

  if ! command -v gh >/dev/null 2>&1; then
    echo 'GitHub CLI is required for the private dotfiles repository. Installing github-cli...'
    sudo pacman -S --needed github-cli
  fi

  if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    echo 'GitHub authentication is required. Complete the device login from your phone when prompted.'
    gh auth login --hostname github.com --git-protocol https --web
  fi

  gh auth setup-git

  if ! GIT_TERMINAL_PROMPT=0 git ls-remote "$DOTFILES_REPO" HEAD >/dev/null 2>&1; then
    printf 'GitHub authentication succeeded, but %s is still inaccessible. Check repository permissions.\n' "$DOTFILES_REPO" >&2
    exit 1
  fi
}

if [[ "$INSTALL_NVIM" == 1 ]]; then
  [[ -n "$DOTFILES_REPO" ]] || {
    echo 'Neovim installation requires AGENTOS_DOTFILES_REPO (or DOTFILES_REPO).' >&2
    exit 2
  }
  DOTFILES_CHECKOUT="$HOME_DIR/src/dotfiles"
  if [[ ! -d "$DOTFILES_CHECKOUT/.git" ]]; then
    ensure_dotfiles_repo_access
  fi
fi

link_path "$SOURCE_DIR/.zshrc" "$HOME_DIR/.zshrc"
link_path "$SOURCE_DIR/.zsh" "$HOME_DIR/.zsh"
link_path "$SOURCE_DIR/.config/kitty" "$HOME_DIR/.config/kitty"
link_path "$SOURCE_DIR/.config/i3" "$HOME_DIR/.config/i3"
link_path "$SOURCE_DIR/.config/starship.toml" "$HOME_DIR/.config/starship.toml"
link_path "$SOURCE_DIR/.config/atuin/config.toml" "$HOME_DIR/.config/atuin/config.toml"
link_path "$SOURCE_DIR/.gitconfig" "$HOME_DIR/.gitconfig"

if [[ "$INSTALL_NVIM" == 1 ]]; then
  if [[ ! -d "$DOTFILES_CHECKOUT/.git" ]]; then
    git clone --depth 1 "$DOTFILES_REPO" "$DOTFILES_CHECKOUT"
  fi
  NVIM_DIR="$HOME_DIR/.config/nvim"
  if [[ -e "$NVIM_DIR" || -L "$NVIM_DIR" ]]; then
    mkdir -p "$BACKUP_DIR/.config"
    mv "$NVIM_DIR" "$BACKUP_DIR/.config/nvim"
  fi
  install -d -m 755 "$NVIM_DIR"
  NVIM_LINUX_PATH="$(lua_single_quote "$SOURCE_DIR/nvim-linux.lua")"
  cat > "$NVIM_DIR/init.lua" <<EOF
dofile(vim.fn.expand('~/src/dotfiles/home/.config/nvim/init.lua'))
dofile('$NVIM_LINUX_PATH')
EOF
fi

if [[ -d "$BACKUP_DIR" ]]; then
  printf 'Previous files moved to %s\n' "$BACKUP_DIR"
fi
echo 'Linux dotfiles installed.'
