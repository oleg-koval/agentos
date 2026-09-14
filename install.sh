#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTOS_REPO="${AGENTOS_REPO:-$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)}"
if [[ -z "$AGENTOS_REPO" && -f "$SCRIPT_DIR/release/source-repository" ]]; then
  AGENTOS_REPO="$(cat "$SCRIPT_DIR/release/source-repository")"
fi
CHANNEL="${AGENTOS_CHANNEL:-$(cat "$SCRIPT_DIR/release/installer-channel" 2>/dev/null || printf stable)}"
case "$CHANNEL" in
  stable|beta|edge) ;;
  *) echo "Unsupported channel: $CHANNEL" >&2; exit 2 ;;
esac
DISK="${DISK:-}"
HOSTNAME="${HOSTNAME:-agentos}"
USERNAME="${USERNAME:-}"
TIMEZONE="${TIMEZONE:-UTC}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"
ENABLE_LUKS="${ENABLE_LUKS:-1}"
LUKS_NAME="${LUKS_NAME:-cryptroot}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
NAS_HOST="${NAS_HOST:-}"
NAS_EXPORT="${NAS_EXPORT:-}"
TUNNEL_NAME="${TUNNEL_NAME:-agentos}"
INSTALL_OPENCODE="${AGENTOS_INSTALL_OPENCODE:-0}"
IDE="${AGENTOS_IDE:-none}"
AGENTOS_PACKAGE_CACHE="${AGENTOS_PACKAGE_CACHE:-$SCRIPT_DIR/cache}"
AGENTOS_INSTALL_REPO="${AGENTOS_INSTALL_REPO:-$SCRIPT_DIR/repository/install/x86_64}"
AGENTOS_LOCAL_REPO="${AGENTOS_LOCAL_REPO:-$SCRIPT_DIR/repository/x86_64}"
OPENCODE_SELECTION_SET=0
IDE_SELECTION_SET=0
[[ -n "${AGENTOS_INSTALL_OPENCODE+x}" ]] && OPENCODE_SELECTION_SET=1
[[ -n "${AGENTOS_IDE+x}" ]] && IDE_SELECTION_SET=1

pick_option() {
  local prompt="$1"
  shift
  local -a options=("$@")
  local selected=0 key sequence index

  while true; do
    printf '\033[2J\033[H'
    printf 'AgentOS setup\n\n%s\n\n' "$prompt"
    for index in "${!options[@]}"; do
      if (( index == selected )); then
        printf '  > %s\n' "${options[$index]}"
      else
        printf '    %s\n' "${options[$index]}"
      fi
    done
    printf '\nUse arrow keys and Enter. Ctrl-C cancels.\n'

    IFS= read -r -s -n 1 key || exit 1
    case "$key" in
      $'\x1b')
        IFS= read -r -s -n 2 -t 1 sequence || continue
        case "$sequence" in
          '[A')
            if (( selected > 0 )); then selected=$((selected - 1)); fi
            ;;
          '[B')
            if (( selected < ${#options[@]} - 1 )); then selected=$((selected + 1)); fi
            ;;
        esac
        ;;
      '')
        REPLY="$selected"
        printf '\033[2J\033[H'
        return 0
        ;;
    esac
  done
}

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [--opencode] [--ide IDE]

Optional IDE values: none, cursor, vscode, webstorm.
Selections are recorded for first-boot convergence; optional tools remain
disabled unless explicitly selected.
EOF
}

while (($# > 0)); do
  case "$1" in
    --opencode) INSTALL_OPENCODE=1; OPENCODE_SELECTION_SET=1 ;;
    --ide)
      (($# >= 2)) || { echo '--ide needs a value' >&2; usage >&2; exit 2; }
      IDE="$2"
      IDE_SELECTION_SET=1
      shift
      ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

select_optional_tools() {
  [[ -t 0 && -t 1 ]] || return 0

  (( OPENCODE_SELECTION_SET || IDE_SELECTION_SET )) && return 0

  local -a choices=(
    'AgentOS essentials only'
    'AgentOS + OpenCode'
    'AgentOS + OpenCode + VS Code'
    'AgentOS + OpenCode + Cursor'
    'AgentOS + OpenCode + WebStorm'
  )
  pick_option 'Choose what to install:' "${choices[@]}"
  case "$REPLY" in
    0) INSTALL_OPENCODE=0; IDE=none ;;
    1) INSTALL_OPENCODE=1; IDE=none ;;
    2) INSTALL_OPENCODE=1; IDE=vscode ;;
    3) INSTALL_OPENCODE=1; IDE=cursor ;;
    4) INSTALL_OPENCODE=1; IDE=webstorm ;;
  esac
}

select_optional_tools

select_install_identity() {
  if [[ -z "$DISK" && -t 0 && -t 1 ]]; then
    command -v lsblk >/dev/null || { echo 'lsblk is required for disk selection.' >&2; exit 1; }
    local name size type model path
    local -a disk_paths=() disk_labels=()
    while read -r name size type model; do
      [[ "$type" == disk ]] || continue
      path="/dev/$name"
      disk_paths+=("$path")
      disk_labels+=("${size:-unknown size} ${model:-disk} ($path)")
    done < <(lsblk -dn -o NAME,SIZE,TYPE,MODEL)
    ((${#disk_paths[@]} > 0)) || { echo 'No installation disk was detected.' >&2; exit 1; }
    pick_option 'Select the disk for AgentOS (the selected disk will be erased):' "${disk_labels[@]}"
    DISK="${disk_paths[$REPLY]}"
  fi
  if [[ -z "$USERNAME" && -t 0 && -t 1 ]]; then
    USERNAME="agent"
  fi
  [[ -n "$DISK" ]] || { echo 'DISK is required; set it explicitly before running install.sh.' >&2; exit 2; }
  [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*[$]?$ && "$USERNAME" != root ]] || {
    echo 'USERNAME must be a non-root Linux login name.' >&2
    exit 2
  }
}

[[ "$INSTALL_OPENCODE" == 0 || "$INSTALL_OPENCODE" == 1 ]] || {
  echo 'AGENTOS_INSTALL_OPENCODE must be 0 or 1.' >&2
  exit 2
}
case "$IDE" in
  none|cursor|vscode|webstorm) ;;
  *) echo "Unsupported IDE: $IDE" >&2; usage >&2; exit 2 ;;
esac

select_install_identity

part_path() {
  local part="$1"
  case "$DISK" in
    /dev/nvme*|/dev/mmcblk*|/dev/loop*|/dev/md*|/dev/nbd*) printf '%sp%s' "$DISK" "$part" ;;
    *) printf '%s%s' "$DISK" "$part" ;;
  esac
}

ROOT_PART="$(part_path 2)"
EFI_PART="$(part_path 1)"
ROOT_DEVICE="$ROOT_PART"
LUKS_UUID=""
BTRFS_UUID=""
EFI_UUID=""

step() { printf '\n==> %s\n' "$1"; }
run() { printf '+ %s\n' "$*"; "$@"; }
need_root() { [[ ${EUID} -eq 0 ]] || { printf 'Run as root.\n' >&2; exit 1; }; }

confirm() {
  if [[ -t 0 && -t 1 ]]; then
    pick_option "Ready to install AgentOS on $DISK. This disk will be erased:" \
      'Cancel installation' "Install AgentOS on $DISK"
    (( REPLY == 1 )) || { echo 'Installation cancelled.' >&2; exit 1; }
    return 0
  fi
  printf 'This will erase %s. Type YES to continue: ' "$DISK"
  read -r answer
  [[ "$answer" == YES ]]
}

require_commands() {
  local cmd
  local -a missing=()
  for cmd in sgdisk cryptsetup mkfs.fat mkfs.btrfs btrfs partprobe udevadm mount umount pacstrap arch-chroot blkid; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  if ((${#missing[@]} > 0)); then
    printf 'Missing installer commands: %s\n' "${missing[*]}" >&2
    return 1
  fi
}

preflight() {
  step 'Preflight'
  need_root
  confirm
  [[ -b "$DISK" ]] || { echo "Target disk not found: $DISK" >&2; return 1; }
  [[ -d /sys/firmware/efi/efivars ]] || {
    echo 'UEFI variables are unavailable; boot this installer in UEFI mode.' >&2
    return 1
  }
  [[ -f "$SCRIPT_DIR/packages.txt" ]]
  [[ -f "$SCRIPT_DIR/apply-system-policy.sh" ]]
  [[ -d "$SCRIPT_DIR/systemd/system" ]]
  [[ -d "$SCRIPT_DIR/systemd/user" ]]
  [[ -d "$SCRIPT_DIR/pacman-hooks" ]]
  require_commands
}

partition_disk() {
  step 'Partition disk'
  run sgdisk --zap-all "$DISK"
  run sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI "$DISK"
  run sgdisk -n 2:0:0 -t 2:8300 -c 2:ROOT "$DISK"
  run partprobe "$DISK"
  run udevadm settle
}

open_luks() {
  if [[ "$ENABLE_LUKS" == 1 ]]; then
    step 'Create LUKS2 container'
    run cryptsetup luksFormat --type luks2 "$ROOT_PART"
    LUKS_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
    run cryptsetup open "$ROOT_PART" "$LUKS_NAME"
    ROOT_DEVICE="/dev/mapper/$LUKS_NAME"
  fi
}

format_filesystems() {
  step 'Format filesystems'
  run mkfs.fat -F32 "$EFI_PART"
  run mkfs.btrfs -f "$ROOT_DEVICE"
}

create_subvolumes() {
  step 'Create Btrfs subvolumes'
  run mount "$ROOT_DEVICE" /mnt
  run btrfs subvolume create /mnt/@
  run btrfs subvolume create /mnt/@home
  run btrfs subvolume create /mnt/@snapshots
  run btrfs subvolume create /mnt/@log
  run btrfs subvolume create /mnt/@pkg
  run btrfs subvolume create /mnt/@tmp
  run umount /mnt
}

mount_filesystems() {
  step 'Mount filesystems'
  run mount -o noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@ "$ROOT_DEVICE" /mnt
  run mkdir -p /mnt/{boot,home,.snapshots,var/log,var/cache/pacman/pkg,var/tmp}
  run mount -o noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@home "$ROOT_DEVICE" /mnt/home
  run mount -o noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@snapshots "$ROOT_DEVICE" /mnt/.snapshots
  run mount -o noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@log "$ROOT_DEVICE" /mnt/var/log
  run mount -o noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@pkg "$ROOT_DEVICE" /mnt/var/cache/pacman/pkg
  run mount -o noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@tmp "$ROOT_DEVICE" /mnt/var/tmp
  run mount "$EFI_PART" /mnt/boot
}

write_fstab() {
  step 'Write fstab'
  BTRFS_UUID="$(blkid -s UUID -o value "$ROOT_DEVICE")"
  EFI_UUID="$(blkid -s UUID -o value "$EFI_PART")"
  if command -v genfstab >/dev/null; then
    run sh -c 'genfstab -U /mnt >> /mnt/etc/fstab'
    return
  fi
  install -d -m 755 /mnt/etc
  cat > /mnt/etc/fstab <<EOF
UUID=${BTRFS_UUID} / btrfs rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@ 0 0
UUID=${BTRFS_UUID} /home btrfs rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@home 0 0
UUID=${BTRFS_UUID} /.snapshots btrfs rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@snapshots 0 0
UUID=${BTRFS_UUID} /var/log btrfs rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@log 0 0
UUID=${BTRFS_UUID} /var/cache/pacman/pkg btrfs rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@pkg 0 0
UUID=${BTRFS_UUID} /var/tmp btrfs rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@tmp 0 0
UUID=${EFI_UUID} /boot vfat umask=0077 0 2
EOF
}

install_base() {
  local packages=()
  local pacman_config=''
  step 'Install base system'
  mapfile -t packages < <(grep -Ev '^[[:space:]]*(#|$)' "$SCRIPT_DIR/packages.txt")
  [[ ${#packages[@]} -gt 0 ]]
  if [[ -f "$AGENTOS_INSTALL_REPO/agentos-install.db.tar.gz" ]]; then
    pacman_config="$(mktemp)"
    awk -v cache="$AGENTOS_PACKAGE_CACHE" -v repo="$AGENTOS_INSTALL_REPO" '
      BEGIN {
        local_repo = "[agentos-install]\nSigLevel = Required DatabaseNever\nServer = file://" repo "\n"
      }
      !cache_added && /^\[options\]$/ {
        print
        print "CacheDir = " cache
        cache_added = 1
        next
      }
      !repo_added && /^\[core\]$/ {
        printf "\n%s", local_repo
        repo_added = 1
      }
      { print }
      END {
        if (!repo_added) printf "\n%s", local_repo
      }
    ' /etc/pacman.conf > "$pacman_config"
    run pacstrap -K -C "$pacman_config" /mnt "${packages[@]}"
    rm -f "$pacman_config"
  elif [[ -d "$AGENTOS_PACKAGE_CACHE" ]] && find "$AGENTOS_PACKAGE_CACHE" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print -quit | grep -q .; then
    pacman_config="$(mktemp)"
    cp /etc/pacman.conf "$pacman_config"
    printf '\nCacheDir = %s\n' "$AGENTOS_PACKAGE_CACHE" >> "$pacman_config"
    run pacstrap -c -K -C "$pacman_config" /mnt "${packages[@]}"
    rm -f "$pacman_config"
  else
    run pacstrap -K /mnt "${packages[@]}"
  fi
}

copy_bootstrap_assets() {
  step 'Copy bootstrap assets'
  local file
  for file in \
    bootstrap.sh update-workstation.sh install-dotfiles.sh install-agent-tools.sh sync-workstation.sh setup-project-layout.sh agentos-support.sh agentos-telemetry.sh \
    apply-system-policy.sh ensure-agentos-config.sh maintenance-check.sh workstation-doctor.sh workstation-alert.sh \
    btrfs-pre-pacman-snapshot.sh btrfs-prune-snapshots.sh rollback-workstation.sh rollback-boot-cleanup.sh \
    hermes-backup.sh migrate-hermes.sh enable-hermes-gateway.sh restic-verify.sh agentos-repository.sh; do
    run cp "$SCRIPT_DIR/$file" "/mnt/root/$file"
    run chmod +x "/mnt/root/$file"
  done
  run cp "$SCRIPT_DIR/AGENTS.md" /mnt/root/AGENTS.md
  run cp -R "$SCRIPT_DIR/.agents" /mnt/root/.agents
  run cp -R "$SCRIPT_DIR/dotfiles" /mnt/root/dotfiles
  run cp -R "$SCRIPT_DIR/systemd" /mnt/root/systemd
  run cp -R "$SCRIPT_DIR/pacman-hooks" /mnt/root/pacman-hooks
  run cp -R "$SCRIPT_DIR/core" /mnt/root/core
  run cp -R "$SCRIPT_DIR/release" /mnt/root/release
  if [[ -d "$AGENTOS_LOCAL_REPO" ]]; then
    run mkdir -p /mnt/root/agentos-repository
    run cp -R "$AGENTOS_LOCAL_REPO"/. /mnt/root/agentos-repository/
  fi
}

chroot_and_bootstrap() {
  step 'Chroot bootstrap'
  run arch-chroot /mnt env \
    HOSTNAME="$HOSTNAME" USERNAME="$USERNAME" TIMEZONE="$TIMEZONE" LOCALE="$LOCALE" KEYMAP="$KEYMAP" \
    ENABLE_LUKS="$ENABLE_LUKS" LUKS_NAME="$LUKS_NAME" LUKS_UUID="$LUKS_UUID" \
    BTRFS_UUID="$BTRFS_UUID" EFI_UUID="$EFI_UUID" SSH_PUBLIC_KEY="$SSH_PUBLIC_KEY" \
    NAS_HOST="$NAS_HOST" NAS_EXPORT="$NAS_EXPORT" TUNNEL_NAME="$TUNNEL_NAME" \
    AGENTOS_LOCAL_REPO="$([[ -d "$AGENTOS_LOCAL_REPO" ]] && printf '%s' /root/agentos-repository || true)" \
    AGENTOS_REPO="$AGENTOS_REPO" AGENTOS_CHANNEL="$CHANNEL" \
    AGENTOS_INSTALL_OPENCODE="$INSTALL_OPENCODE" AGENTOS_IDE="$IDE" \
    /root/bootstrap.sh
}

cleanup_and_finish() {
  step 'Cleanup'
  run umount -R /mnt
  step 'Done'
  printf 'Reboot into Arch, then follow /home/%s/ops/first-boot.md.\n' "$USERNAME"
}

main() {
  preflight
  partition_disk
  open_luks
  format_filesystems
  create_subvolumes
  mount_filesystems
  install_base
  write_fstab
  copy_bootstrap_assets
  chroot_and_bootstrap
  cleanup_and_finish
}

main "$@"
