#!/usr/bin/env bash
# Pull the latest AgentOS configuration and converge this machine onto it.
set -euo pipefail

REPO="${AGENTOS_REPO:-${LEGACY_WORKSTATION_REPO:-}}"
CHECKOUT="${AGENTOS_CHECKOUT:-${LEGACY_WORKSTATION_CHECKOUT:-$HOME/.local/share/agentos/repo}}"
if [[ ! -e "$CHECKOUT" && -d "$HOME/.local/share/legacy-workstation/repo" ]]; then
  CHECKOUT="$HOME/.local/share/legacy-workstation/repo"
fi
MODE=sync
TOOLING_CONFIG="${AGENTOS_TOOLING_CONFIG:-$HOME/.config/agentos/tooling.env}"
INSTALL_OPENCODE="${AGENTOS_INSTALL_OPENCODE:-}"
IDE="${AGENTOS_IDE:-}"
GENERATION=""

read_tooling_value() {
  local key="$1"
  sed -n -E "s/^${key}=([[:alnum:]_-]+)$/\\1/p" "$TOOLING_CONFIG" 2>/dev/null | head -n 1
}

if [[ -z "$INSTALL_OPENCODE" && -f "$TOOLING_CONFIG" ]]; then
  INSTALL_OPENCODE="$(read_tooling_value AGENTOS_INSTALL_OPENCODE)"
fi
if [[ -z "$IDE" && -f "$TOOLING_CONFIG" ]]; then
  IDE="$(read_tooling_value AGENTOS_IDE)"
fi
INSTALL_OPENCODE="${INSTALL_OPENCODE:-0}"
IDE="${IDE:-none}"

OPTIONAL_ARGS=()
while (($# > 0)); do
  case "$1" in
    sync) MODE=sync ;;
    --apply) MODE=--apply ;;
    --opencode) INSTALL_OPENCODE=1; OPTIONAL_ARGS+=(--opencode) ;;
    --ide)
      (($# >= 2)) || { echo '--ide needs a value' >&2; exit 2; }
      IDE="$2"
      OPTIONAL_ARGS+=(--ide "$2")
      shift
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$MODE" in sync|--apply) ;; *) echo 'Usage: sync-workstation [--opencode] [--ide IDE]' >&2; exit 2 ;; esac
case "$IDE" in none|cursor|vscode|webstorm) ;; *) echo "Unsupported IDE: $IDE" >&2; exit 2 ;; esac
if (( INSTALL_OPENCODE )) && [[ ! " ${OPTIONAL_ARGS[*]} " == *' --opencode '* ]]; then OPTIONAL_ARGS+=(--opencode); fi
if [[ "$IDE" != none && ! " ${OPTIONAL_ARGS[*]} " == *" --ide $IDE "* ]]; then OPTIONAL_ARGS+=(--ide "$IDE"); fi

if [[ ${EUID} -eq 0 ]]; then
  echo 'Run sync-workstation as the workstation user, not root.' >&2
  exit 1
fi

step() { printf '\n==> %s\n' "$1"; }

normalize_repository() {
  local repository="${1%/}"
  repository="${repository%.git}"
  case "$repository" in
    https://github.com/*) printf 'github.com/%s\n' "${repository#https://github.com/}" ;;
    ssh://git@github.com/*) printf 'github.com/%s\n' "${repository#ssh://git@github.com/}" ;;
    git@github.com:*) printf 'github.com/%s\n' "${repository#git@github.com:}" ;;
    *) printf '%s\n' "$repository" ;;
  esac
}

resolve_repository() {
  if [[ -z "$REPO" && -r /etc/agentos/repository-url ]]; then
    REPO="$(sed -n '1p' /etc/agentos/repository-url)"
  fi
  if [[ -z "$REPO" && -d "$CHECKOUT/.git" ]]; then
    REPO="$(git -C "$CHECKOUT" remote get-url origin 2>/dev/null || true)"
  fi
  [[ -n "$REPO" ]] || {
    echo 'AGENTOS_REPO is not configured and no existing checkout remote was found.' >&2
    echo 'Set AGENTOS_REPO to the canonical AgentOS source repository and rerun sync-workstation.' >&2
    exit 2
  }
}

ensure_bootstrap_tools() {
  if command -v git >/dev/null 2>&1 && command -v gh >/dev/null 2>&1; then return; fi
  step 'Bootstrap sync tools'
  sudo pacman -S --needed --noconfirm git github-cli
}

ensure_github_auth() {
  if gh auth status --hostname github.com >/dev/null 2>&1; then gh auth setup-git >/dev/null; return; fi
  step 'GitHub authentication'
  echo 'Authorize GitHub from your phone/browser when prompted.'
  gh auth login --hostname github.com --git-protocol https --web
  gh auth setup-git
}

pull_repo() {
  local origin
  step 'Repository sync'
  mkdir -p "$(dirname "$CHECKOUT")"
  if [[ ! -d "$CHECKOUT/.git" ]]; then gh repo clone "$REPO" "$CHECKOUT"; return; fi
  origin="$(git -C "$CHECKOUT" remote get-url origin 2>/dev/null)" || {
    echo "Refusing to sync because $CHECKOUT has no readable origin remote." >&2
    echo 'Configure its origin to match AGENTOS_REPO, or use another AGENTOS_CHECKOUT.' >&2
    exit 1
  }
  if [[ "$(normalize_repository "$REPO")" != "$(normalize_repository "$origin")" ]]; then
    echo "Refusing to sync because $CHECKOUT origin ($origin) does not match the configured repository ($REPO)." >&2
    echo 'Set AGENTOS_REPO to the checkout origin, fix the origin, or use another AGENTOS_CHECKOUT.' >&2
    exit 1
  fi
  if ! git -C "$CHECKOUT" diff --quiet || ! git -C "$CHECKOUT" diff --cached --quiet; then
    echo "Refusing to sync because $CHECKOUT has local changes." >&2
    echo 'Commit/stash them first, or use another AGENTOS_CHECKOUT.' >&2
    exit 1
  fi
  git -C "$CHECKOUT" fetch origin main
  git -C "$CHECKOUT" checkout main
  git -C "$CHECKOUT" pull --ff-only origin main
}

load_packages() {
  local manifest="$CHECKOUT/packages.txt"
  [[ -f "$manifest" ]] || { echo "Missing package manifest: $manifest" >&2; exit 1; }
  mapfile -t PACKAGES < <(grep -Ev '^[[:space:]]*(#|$)' "$manifest")
  [[ ${#PACKAGES[@]} -gt 0 ]] || { echo 'Package manifest is empty.' >&2; exit 1; }
}

apply_system_policy() { step 'System policy'; sudo env WORKSTATION_USER="$USER" AGENTOS_REPO="$REPO" bash "$CHECKOUT/apply-system-policy.sh" "$CHECKOUT"; }
install_system_packages() { step 'System packages'; load_packages; sudo pacman -Syu --needed --noconfirm "${PACKAGES[@]}"; }

sync_dotfiles() {
  step 'Dotfiles'
  local managed="$HOME/.local/share/agentos/dotfiles"
  if [[ ! -d "$managed" && -d "$HOME/.local/share/legacy-workstation/dotfiles" ]]; then
    managed="$HOME/.local/share/legacy-workstation/dotfiles"
  fi
  rm -rf "$managed"; mkdir -p "$(dirname "$managed")"; cp -a "$CHECKOUT/dotfiles" "$managed"; bash "$CHECKOUT/install-dotfiles.sh"
}

setup_project_layout() { step 'Project layout'; setup-project-layout; }
sync_agentos_desktop() { step 'AgentOS desktop layer'; AGENTOS_SOURCE_DIR="$CHECKOUT" agentos-desktop --sync; }
update_tools() {
  step 'Explicit workstation/tool update'
  sudo env WORKSTATION_USER="$USER" AGENTOS_INSTALL_OPENCODE="$INSTALL_OPENCODE" AGENTOS_IDE="$IDE" \
    bash "$CHECKOUT/update-workstation.sh"
}

activate_services() {
  step 'Reliability services'
  sudo systemctl daemon-reload
  sudo systemctl start workstation-maintenance-check.timer workstation-health-check.timer restic-verify.timer agentos-weekly-update.timer

  systemctl --user daemon-reload || true
  if ! systemctl --user enable agentosd.service agentos-herdr-bridge.service hermes-backup-quick.timer hermes-backup-full.timer; then
    echo 'Could not enable all user services in this session; global enablement is installed and they will activate with the user manager.' >&2
  fi

  # The policy step can replace runtime binaries while the old processes remain
  # alive. Validate the newly installed runtime, never a stale process.
  systemctl --user restart agentosd.service
  systemctl --user restart agentos-herdr-bridge.service
  systemctl --user start hermes-backup-quick.timer hermes-backup-full.timer
}

mark_failed() {
  local rc=$?
  trap - ERR
  if [[ -n "$GENERATION" ]]; then
    bash "$CHECKOUT/agentos-transaction.sh" fail "$GENERATION" || true
  fi
  echo 'AgentOS convergence aborted. The pre-change recovery snapshot was preserved and rollback may be staged for the next boot.' >&2
  exit "$rc"
}

begin_transaction() {
  step 'Convergence preflight'
  [[ -x "$CHECKOUT/agentos-transaction.sh" || -f "$CHECKOUT/agentos-transaction.sh" ]] || { echo 'Missing transaction guard.' >&2; exit 1; }
  AGENTOS_CHECKOUT="$CHECKOUT" bash "$CHECKOUT/agentos-transaction.sh" preflight
  GENERATION="$(cat "$HOME/.local/share/agentos/generations/current")"
  [[ -n "$GENERATION" ]] || { echo 'Transaction guard did not create a generation.' >&2; exit 1; }
  trap mark_failed ERR
}

validate_transaction() {
  local snapshot
  step 'Convergence validation'
  AGENTOS_CHECKOUT="$CHECKOUT" bash "$CHECKOUT/agentos-transaction.sh" validate "$GENERATION"
  trap - ERR

  snapshot="$(jq -r '.snapshot // empty' "$HOME/.local/share/agentos/generations/$GENERATION/after.json")"
  [[ -n "$snapshot" ]] || { echo 'GOOD generation has no recovery snapshot; boot gate cannot be armed.' >&2; return 1; }
  step 'Candidate boot gate'
  sudo agentos-boot-health arm "$GENERATION" "$snapshot"
}

apply_latest() {
  begin_transaction

  install_system_packages
  apply_system_policy
  sync_dotfiles
  setup_project_layout
  sync_agentos_desktop
  update_tools
  activate_services
  validate_transaction

  step 'Done'
  printf 'Workstation converged to %s at %s\n' "$REPO" "$(git -C "$CHECKOUT" rev-parse --short HEAD)"
  printf 'AgentOS generation %s is GOOD and armed for next-boot health validation.\n' "$GENERATION"
  echo 'Persistent agent runtime, shell, Herdr lifecycle bridge and reliability services are installed.'
  echo 'SSH, Tailscale and configured KRDP were validated as protected remote-access invariants.'
}

main() {
  resolve_repository
  ensure_bootstrap_tools
  ensure_github_auth
  if [[ "$MODE" == --apply ]]; then apply_latest; return; fi
  [[ "$MODE" == sync ]] || { echo 'Usage: sync-workstation' >&2; exit 2; }
  pull_repo
  exec bash "$CHECKOUT/sync-workstation.sh" --apply "${OPTIONAL_ARGS[@]}"
}

main "$@"
