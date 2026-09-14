#!/usr/bin/env bash
# Safe bootstrap for an already-provisioned Arch VPS. This script never
# partitions, formats, mounts, or changes SSH/firewall configuration.
set -euo pipefail

PACMAN_CONF="${AGENTOS_VPS_PACMAN_CONF:-/etc/pacman.conf}"
PACMAN_INCLUDE="${AGENTOS_VPS_INCLUDE:-/etc/pacman.d/agentos.conf}"
STATE_DIR="${AGENTOS_VPS_STATE_DIR:-/var/lib/agentos/vps-installer}"
CONFIG_FILE="${AGENTOS_VPS_CONFIG_FILE:-/etc/agentos/config.yaml}"
ROLE_FILE="${AGENTOS_VPS_ROLE_FILE:-/etc/agentos/role}"
CHANNEL_FILE="${AGENTOS_VPS_CHANNEL_FILE:-/etc/agentos/channel}"
TEST_MODE="${AGENTOS_VPS_TEST_MODE:-0}"
CREATE_PROJECT_ROOTS="${AGENTOS_VPS_CREATE_PROJECT_ROOTS:-1}"
# These defaults are intentionally embedded because the published standalone
# installer is copied without release/repository.env. Keep them synchronized
# with that canonical file; tests/repository-trust.sh rejects drift.
DEFAULT_REPO_BASE_URL='https://oleg-koval.github.io/agentos'
DEFAULT_KEY_URL="${DEFAULT_REPO_BASE_URL}/agentos-signing.asc"
DEFAULT_FINGERPRINT='EAC73D1D595C8F7D809D42EB268D28C12D93BC1B'
BEGIN='# BEGIN AGENTOS REPOSITORY'
END='# END AGENTOS REPOSITORY'

usage() {
  cat <<'EOF'
Usage:
  sudo agentos-vps-install --repo-url URL --repo-key-url URL \
    --fingerprint FINGERPRINT [--user USER] [--role vps] [--channel CHANNEL] \
    [--project-root PATH] [--agents LIST] [--tailscale] [--krdp] [--yes]
  sudo agentos-vps-install --reset

The default is a non-mutating plan. Add --yes to apply it. The VPS must already
be an installed, networked Arch/systemd host with SSH access. Repository URLs
and public-key URLs must use HTTPS; the key fingerprint must be the full
40-character published fingerprint.

--user USER       Existing non-root user whose AgentOS user services are enabled.
                  Defaults to SUDO_USER when available.
--role vps        Machine role for this installer. The VPS bootstrap accepts vps.
--channel CHANNEL Initial AgentOS channel: stable, beta, or edge (default: stable).
--project-root PATH  User project root; may be repeated (default: USER home/src).
--agents LIST     Comma-separated enabled agents: claude,codex,hermes,herdr.
                  Defaults to claude,codex. Use an empty list to enable none.
--tailscale       Require Tailscale in the final onboarding validation.
--krdp            Require KRDP in the final onboarding validation.
--reset           Restore the most recent saved pacman/repository configuration.
EOF
}

die() { printf 'agentos-vps-install: %s\n' "$1" >&2; exit "${2:-1}"; }
log() { printf '==> %s\n' "$1"; }
as_root() { "$@"; }

[[ ${EUID} -eq 0 || "$TEST_MODE" == 1 ]] || die 'run as root (for example: sudo agentos-vps-install ...)' 1

repo_url=''
key_url=''
fingerprint=''
workstation_user="${SUDO_USER:-}"
machine_role=vps
channel=stable
project_roots=()
custom_project_roots=0
agents=(claude codex)
want_tailscale=0
want_krdp=0
apply=0
reset=0

while (($# > 0)); do
  case "$1" in
    --repo-url) (($# >= 2)) || die '--repo-url needs a value' 2; repo_url="$2"; shift ;;
    --repo-key-url) (($# >= 2)) || die '--repo-key-url needs a value' 2; key_url="$2"; shift ;;
    --fingerprint) (($# >= 2)) || die '--fingerprint needs a value' 2; fingerprint="$2"; shift ;;
    --user) (($# >= 2)) || die '--user needs a value' 2; workstation_user="$2"; shift ;;
    --role) (($# >= 2)) || die '--role needs a value' 2; machine_role="$2"; shift ;;
    --channel) (($# >= 2)) || die '--channel needs a value' 2; channel="$2"; shift ;;
    --project-root)
      (($# >= 2)) || die '--project-root needs a value' 2
      if (( ! custom_project_roots )); then project_roots=(); custom_project_roots=1; fi
      project_roots+=("$2")
      shift
      ;;
    --agents) (($# >= 2)) || die '--agents needs a value' 2; IFS=',' read -r -a agents <<<"$2"; shift ;;
    --tailscale) want_tailscale=1 ;;
    --krdp) want_krdp=1 ;;
    --yes) apply=1 ;;
    --reset) reset=1 ;;
    -h|--help|help) usage; exit 0 ;;
    *) die "unknown option: $1" 2 ;;
  esac
  shift
done

normalize_fingerprint() { tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'; }
actual_fingerprint() {
  gpg --show-keys --with-colons "$1" 2>/dev/null \
    | awk -F: '$1 == "fpr" {print $10; exit}' | normalize_fingerprint
}

backup_file() {
  local source="$1" destination="$2"
  if [[ -e "$source" ]]; then
    cp -a "$source" "$destination"
    touch "${destination}.present"
  fi
}

latest_backup() {
  [[ -d "$STATE_DIR" ]] || return 1
  find "$STATE_DIR" -mindepth 1 -maxdepth 1 -type d -name 'backup-*' -print \
    | sort | tail -n 1
}

restore_file() {
  local backup="$1" target="$2"
  if [[ -e "${backup}.present" ]]; then
    install -d -m 755 "$(dirname "$target")"
    install -m 644 "$backup" "$target"
  else
    rm -f "$target"
  fi
}

yaml_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

write_first_run_config() {
  local config_tmp role_tmp channel_tmp agent project_root
  install -d -m 755 "$(dirname "$CONFIG_FILE")" "$(dirname "$ROLE_FILE")" "$(dirname "$CHANNEL_FILE")"

  if [[ "$CREATE_PROJECT_ROOTS" == 1 ]]; then
    for project_root in "${project_roots[@]}"; do
      runuser -u "$workstation_user" -- mkdir -p "$project_root"
    done
  fi

  config_tmp="$(mktemp "${CONFIG_FILE}.XXXXXX")"
  {
    printf 'version: 1\nchannel: %s\nremote_access:\n  ssh: true\n  tailscale: %s\n  krdp: %s\nagents:\n' \
      "$channel" "$([[ $want_tailscale -eq 1 ]] && echo true || echo false)" \
      "$([[ $want_krdp -eq 1 ]] && echo true || echo false)"
    for agent in "${agents[@]}"; do
      [[ -n "$agent" ]] && printf '  %s: true\n' "$agent"
    done
    printf 'models:\nproject_roots:\n'
    for project_root in "${project_roots[@]}"; do
      printf '  - %s\n' "$(yaml_string "$project_root")"
    done
    printf 'backup:\n  enabled: false\n  schedule: weekly\n  target: %s\npower:\n  sleep: disabled\n  hibernate: disabled\n' \
      "$(yaml_string "$home/.config/agentos/hermes-backup-recipients.txt")"
  } > "$config_tmp"
  install -m 644 "$config_tmp" "$CONFIG_FILE"
  rm -f "$config_tmp"

  role_tmp="$(mktemp "${ROLE_FILE}.XXXXXX")"
  printf '%s\n' "$machine_role" > "$role_tmp"
  install -m 644 "$role_tmp" "$ROLE_FILE"
  rm -f "$role_tmp"

  channel_tmp="$(mktemp "${CHANNEL_FILE}.XXXXXX")"
  printf '%s\n' "$channel" > "$channel_tmp"
  install -m 644 "$channel_tmp" "$CHANNEL_FILE"
  rm -f "$channel_tmp"
}

reset_configuration() {
  local backup
  backup="$(latest_backup)" || die "no VPS installer backup found under $STATE_DIR" 1
  [[ -f "$backup/metadata" ]] || die "invalid VPS installer backup: $backup" 1
  restore_file "$backup/pacman.conf" "$PACMAN_CONF"
  restore_file "$backup/agentos.conf" "$PACMAN_INCLUDE"
  restore_file "$backup/repository.json" "${AGENTOS_STATE_DIR:-/var/lib/agentos}/repository.json"
  restore_file "$backup/config.yaml" "$CONFIG_FILE"
  restore_file "$backup/role" "$ROLE_FILE"
  restore_file "$backup/channel" "$CHANNEL_FILE"
  printf 'Restored repository configuration from %s. Imported key trust and packages were left unchanged.\n' "$backup"
}

if (( reset )); then
  (($# == 0)) || true
  reset_configuration
  exit 0
fi

repo_env_file="${AGENTOS_VPS_REPOSITORY_ENV:-$(dirname "${BASH_SOURCE[0]}")/release/repository.env}"
if [[ -f "$repo_env_file" ]]; then
  # shellcheck disable=SC1090
  source "$repo_env_file"
  [[ -n "$repo_url" || -z "${AGENTOS_REPO_BASE_URL:-}" ]] || repo_url="${AGENTOS_REPO_BASE_URL}/${channel}"
  [[ -n "$key_url" || -z "${AGENTOS_REPO_BASE_URL:-}" ]] || key_url="${AGENTOS_REPO_BASE_URL}/agentos-signing.asc"
  [[ -n "$fingerprint" || -z "${AGENTOS_SIGNING_FINGERPRINT:-}" ]] || fingerprint="${AGENTOS_SIGNING_FINGERPRINT}"
fi

[[ -n "$repo_url" ]] || repo_url="${DEFAULT_REPO_BASE_URL}/${channel}"
[[ -n "$key_url" ]] || key_url="$DEFAULT_KEY_URL"
[[ -n "$repo_url" ]] || die '--repo-url is required (no release/repository.env found to default from)' 2
[[ -n "$key_url" ]] || die '--repo-key-url is required (no release/repository.env found to default from)' 2
[[ -n "$fingerprint" ]] || fingerprint="$DEFAULT_FINGERPRINT"
repo_url="${repo_url%/}"
fingerprint="$(printf '%s' "$fingerprint" | normalize_fingerprint)"
[[ "$repo_url" == https://* && "$repo_url" != *[[:space:]]* ]] \
  || die 'repository URL must use HTTPS' 2
[[ "$key_url" == https://* && "$key_url" != *[[:space:]]* ]] \
  || die 'repository key URL must use HTTPS' 2
[[ "$fingerprint" =~ ^[[:xdigit:]]{40}$ ]] \
  || die 'fingerprint must be a full 40-character value' 2
[[ "$machine_role" == vps ]] || die 'this installer only supports --role vps' 2
case "$channel" in stable|beta|edge) ;; *) die 'channel must be stable, beta, or edge' 2 ;; esac

[[ -f "$PACMAN_CONF" ]] || die "pacman configuration not found: $PACMAN_CONF" 1
[[ -n "$workstation_user" ]] || die 'an existing --user is required when SUDO_USER is unavailable' 1
[[ "$workstation_user" != root && "$workstation_user" =~ ^[a-z_][a-z0-9_-]*$ ]] \
  || die "invalid non-root user: $workstation_user" 2

required_commands=(curl gpg pacman pacman-key systemctl ss sshd awk grep install mktemp cp rm find sort tail id getent runuser loginctl)
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name" 1
done

if [[ "$TEST_MODE" != 1 ]]; then
  # The installer is for an already-provisioned Arch VPS, never an installer
  # environment. Check identity without changing any state.
  . /etc/os-release
  [[ "${ID:-}" == arch || "${ID_LIKE:-}" == *arch* ]] || die 'the target is not an Arch Linux host' 1
  command -v ps >/dev/null 2>&1 || die 'ps is required to verify systemd' 1
  [[ "$(ps -p 1 -o comm= 2>/dev/null)" == systemd ]] || die 'systemd must be PID 1' 1
fi

id -u "$workstation_user" >/dev/null 2>&1 || die "user does not exist: $workstation_user" 1
home="$(getent passwd "$workstation_user" | cut -d: -f6)"
[[ -n "$home" && -d "$home" ]] || die "home directory is missing for $workstation_user" 1
(( ${#project_roots[@]} > 0 )) || project_roots=("$home/src")
for project_root in "${project_roots[@]}"; do
  [[ "$project_root" == /* && "$project_root" != '/' && "$project_root" != *$'\n'* && "$project_root" != *$'\r'* ]] \
    || die "project root must be a non-root absolute path: $project_root" 2
  [[ "$project_root" == "$home"/* ]] \
    || die "project root must be inside $home: $project_root" 2
  [[ "$project_root" != *'/../'* && "$project_root" != */.. && "$project_root" != *'/./'* && "$project_root" != */. ]] \
    || die "project root must not contain dot path components: $project_root" 2
done
for agent in "${agents[@]}"; do
  case "$agent" in claude|codex|hermes|herdr|'') ;; *) die "unsupported agent: $agent" 2 ;; esac
done
[[ "$CREATE_PROJECT_ROOTS" == 0 || "$CREATE_PROJECT_ROOTS" == 1 ]] \
  || die 'AGENTOS_VPS_CREATE_PROJECT_ROOTS must be 0 or 1' 2
systemctl is-active --quiet sshd || die 'sshd is not active; no changes were attempted' 1
ss -ltn | awk 'NR > 1 {print $4}' | grep -Eq '(^|:)22$' \
  || die 'sshd is not listening on TCP port 22; no changes were attempted' 1
sshd -t >/dev/null 2>&1 || die 'sshd configuration is invalid; no changes were attempted' 1

key_file="$(mktemp)"
trap 'rm -f "$key_file"' EXIT
curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 "$key_url" -o "$key_file" \
  || die 'could not download the published repository key' 1
actual="$(actual_fingerprint "$key_file")"
[[ "$actual" == "$fingerprint" ]] \
  || die "repository key fingerprint mismatch: expected=$fingerprint actual=${actual:-unknown}" 1

printf '\nPlanned changes:\n'
printf '  - import and locally trust the published AgentOS signing key %s\n' "$fingerprint"
printf '  - manage %s and one Include line in %s\n' "$PACMAN_INCLUDE" "$PACMAN_CONF"
printf '  - install signed packages: agentos-runtime agentos-shell\n'
printf '  - enable AgentOS system/user policy for existing user %s\n' "$workstation_user"
printf '  - configure machine role %s and update channel %s\n' "$machine_role" "$channel"
printf '  - save %d project root(s) and enable agents: %s\n' "${#project_roots[@]}" "${agents[*]:-none}"
printf '  - run local onboarding validation%s%s\n' \
  "$([[ $want_tailscale -eq 1 ]] && printf ' (Tailscale required)' || true)" \
  "$([[ $want_krdp -eq 1 ]] && printf ' (KRDP required)' || true)"
printf '  - SSH configuration, firewall rules, disks, mounts, and reboot: unchanged\n\n'

if (( ! apply )); then
  printf 'Dry run only. Re-run the exact command with --yes to apply these changes.\n'
  exit 0
fi

backup_base="${STATE_DIR}/backup-$(date -u +%Y%m%d-%H%M%S)"
backup="$backup_base"
backup_suffix=0
while [[ -e "$backup" ]]; do
  backup_suffix=$((backup_suffix + 1))
  backup="${backup_base}-${backup_suffix}"
done
install -d -m 700 "$backup"
backup_file "$PACMAN_CONF" "$backup/pacman.conf"
backup_file "$PACMAN_INCLUDE" "$backup/agentos.conf"
repository_state="${AGENTOS_STATE_DIR:-/var/lib/agentos}/repository.json"
backup_file "$repository_state" "$backup/repository.json"
backup_file "$CONFIG_FILE" "$backup/config.yaml"
backup_file "$ROLE_FILE" "$backup/role"
backup_file "$CHANNEL_FILE" "$backup/channel"
printf 'pacman_conf=%s\ninclude=%s\nrepository_state=%s\nconfig=%s\nrole=%s\nchannel=%s\n' \
  "$PACMAN_CONF" "$PACMAN_INCLUDE" "$repository_state" "$CONFIG_FILE" "$ROLE_FILE" "$CHANNEL_FILE" > "$backup/metadata"
chmod 600 "$backup/metadata"

log 'Importing the verified signing key'
pacman-key --add "$key_file" >/dev/null
pacman-key --lsign-key "$fingerprint" >/dev/null

log 'Configuring the signed AgentOS repository'
include_dir="$(dirname "$PACMAN_INCLUDE")"
install -d -m 755 "$include_dir"
include_tmp="$(mktemp "${PACMAN_INCLUDE}.XXXXXX")"
cat > "$include_tmp" <<EOF
# Managed by agentos-vps-install. Do not weaken signature verification.
[agentos]
SigLevel = Required
Server = $repo_url
EOF
install -m 644 "$include_tmp" "$PACMAN_INCLUDE"
rm -f "$include_tmp"
pacman_tmp="$(mktemp "${PACMAN_CONF}.XXXXXX")"
awk -v include_path="$PACMAN_INCLUDE" -v begin="$BEGIN" -v end="$END" '
  $0 == begin {skip=1; next}
  skip && $0 == end {skip=0; next}
  skip && $0 ~ /^[[:space:]]*\[/ {skip=0}
  skip {next}
  $0 ~ /^[[:space:]]*Include[[:space:]]*=[[:space:]]*/ {if ($0 ~ "^[[:space:]]*Include[[:space:]]*=[[:space:]]*" include_path "[[:space:]]*$") next}
  {print}
  END {print ""; print begin; print "Include = " include_path; print end}
' "$PACMAN_CONF" > "$pacman_tmp"
install -m 644 "$pacman_tmp" "$PACMAN_CONF"
rm -f "$pacman_tmp"
install -d -m 755 "$(dirname "$repository_state")"
state_tmp="$(mktemp "${repository_state}.XXXXXX")"
json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}
repo_url_json="$(json_escape "$repo_url")"
fingerprint_json="$(json_escape "$fingerprint")"
include_json="$(json_escape "$PACMAN_INCLUDE")"
configured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"schema":"agentos.repository/v1","configured":true,"url":"%s","fingerprint":"%s","include":"%s","configured_at":"%s"}\n' \
  "$repo_url_json" "$fingerprint_json" "$include_json" "$configured_at" > "$state_tmp"
install -m 644 "$state_tmp" "$repository_state"
rm -f "$state_tmp"

log 'Refreshing signed package metadata and installing AgentOS'
pacman -Syu --needed --noconfirm agentos-runtime agentos-shell
log 'Verifying signed repository configuration after the package transaction'
agentos-repository repair

log 'Installing selected user-scoped agents'
agent_installer="${AGENTOS_VPS_AGENT_INSTALLER:-/usr/bin/install-agent-tools}"
if [[ -z "${AGENTOS_VPS_AGENT_INSTALLER:-}" && ! -x "$agent_installer" ]]; then
  agent_installer=/usr/local/bin/install-agent-tools
fi
agent_list=''
if ((${#agents[@]} > 0)); then
  agent_list="$(IFS=,; printf '%s' "${agents[*]}")"
  if [[ -x "$agent_installer" ]]; then
    if ! runuser -u "$workstation_user" -- env HOME="$home" USER="$workstation_user" \
      PATH="$home/.local/bin:/usr/bin:/bin" "$agent_installer" --agents "$agent_list"; then
      printf 'WARNING: optional agent installation failed; core AgentOS setup will continue.\n' >&2
      printf 'Resume after reviewing the cause with: sudo -H -u %q env PATH=%q %q --agents %q\n' \
        "$workstation_user" "$home/.local/bin:/usr/bin:/bin" "$agent_installer" "$agent_list" >&2
    fi
  else
    printf 'WARNING: selected agents were recorded but %s is unavailable.\n' "$agent_installer" >&2
    printf 'Resume after installing the runtime package with: sudo -H -u %q env PATH=%q install-agent-tools --agents %q\n' \
      "$workstation_user" "$home/.local/bin:/usr/bin:/bin" "$agent_list" >&2
  fi
else
  echo 'No user-scoped agents selected; continuing with core AgentOS setup.'
fi

log 'Applying existing AgentOS service policy'
agentos-power-policy apply
systemctl daemon-reload
systemctl enable agentos-boot-health.service agentos-weekly-update.timer \
  workstation-maintenance-check.timer workstation-health-check.timer \
  restic-verify.timer workstation-rollback-cleanup.service >/dev/null
systemctl --global enable agentosd.service agentos-herdr-bridge.service agentos-home.service \
  hermes-backup-quick.timer hermes-backup-full.timer >/dev/null
loginctl enable-linger "$workstation_user"
uid="$(id -u "$workstation_user")"
systemctl start "user@${uid}.service"
runuser -u "$workstation_user" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
  systemctl --user daemon-reload
runuser -u "$workstation_user" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
  systemctl --user enable --now agentosd.service agentos-herdr-bridge.service
runuser -u "$workstation_user" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
  systemctl --user enable agentos-home.service

log 'Writing first-run machine configuration'
write_first_run_config

log 'Running onboarding validation'
onboarding=(agentos-onboarding --local)
(( want_tailscale )) && onboarding+=(--tailscale)
(( want_krdp )) && onboarding+=(--krdp)
"${onboarding[@]}"
printf '\nAgentOS VPS bootstrap completed. Recovery configuration is stored at %s.\n' "$backup"
