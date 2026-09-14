#!/usr/bin/env bash
set -euo pipefail

HOSTNAME="${HOSTNAME:-agentos}"
USERNAME="${USERNAME:-${SUDO_USER:-}}"
TIMEZONE="${TIMEZONE:-UTC}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"
ENABLE_LUKS="${ENABLE_LUKS:-1}"
LUKS_NAME="${LUKS_NAME:-cryptroot}"
LUKS_UUID="${LUKS_UUID:-}"
BTRFS_UUID="${BTRFS_UUID:-}"
EFI_UUID="${EFI_UUID:-}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
AGENTOS_REPO="${AGENTOS_REPO:-}"
AGENTOS_LOCAL_REPO="${AGENTOS_LOCAL_REPO:-}"
NAS_HOST="${NAS_HOST:-}"
NAS_EXPORT="${NAS_EXPORT:-}"
TUNNEL_NAME="${TUNNEL_NAME:-agentos}"
INSTALL_OPENCODE="${AGENTOS_INSTALL_OPENCODE:-0}"
IDE="${AGENTOS_IDE:-none}"
CHANNEL="${AGENTOS_CHANNEL:-stable}"
CPU_UCODE="${CPU_UCODE:-}"

[[ "$INSTALL_OPENCODE" == 0 || "$INSTALL_OPENCODE" == 1 ]] || {
  echo 'AGENTOS_INSTALL_OPENCODE must be 0 or 1.' >&2
  exit 2
}
case "$IDE" in
  none|cursor|vscode|webstorm) ;;
  *) echo "Unsupported IDE: $IDE" >&2; exit 2 ;;
esac
case "$CHANNEL" in
  stable|beta|edge|none) ;;
  *) echo "Unsupported channel: $CHANNEL" >&2; exit 2 ;;
esac

[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*[$]?$ && "$USERNAME" != root ]] || {
  echo 'USERNAME must be a non-root Linux login name.' >&2
  exit 2
}

step() {
  printf '\n==> %s\n' "$1"
}

step 'Timezone and locale'
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
sed -i "s/^#\(${LOCALE} UTF-8\)/\1/" /etc/locale.gen
printf 'LANG=%s\n' "$LOCALE" > /etc/locale.conf
printf 'KEYMAP=%s\n' "$KEYMAP" > /etc/vconsole.conf
locale-gen

step 'Hostname and hosts'
printf '%s\n' "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

step 'Package manager defaults'
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf

step 'User and sudo'
useradd -m -G wheel -s /bin/zsh "$USERNAME"
passwd "$USERNAME"
install -d -m 755 /etc/sudoers.d
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel
install -d -m 700 "/home/${USERNAME}/.ssh"
if [[ -n "$SSH_PUBLIC_KEY" ]]; then
  printf '%s\n' "$SSH_PUBLIC_KEY" > "/home/${USERNAME}/.ssh/authorized_keys"
  chmod 600 "/home/${USERNAME}/.ssh/authorized_keys"
fi
chown -R "$USERNAME:$USERNAME" "/home/${USERNAME}/.ssh"

step 'SSH and network hardening'
install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-hardening.conf <<CONF
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers ${USERNAME}
CONF

step 'Zram and power defaults'
cat > /etc/systemd/zram-generator.conf <<ZRAM
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAM
systemctl enable power-profiles-daemon

step 'Update mkinitcpio for encrypted root'
if [[ "$ENABLE_LUKS" == 1 ]]; then
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
fi
mkinitcpio -P

step 'CPU microcode detection'
if [[ -z "$CPU_UCODE" ]]; then
  cpu_vendor="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
  case "$cpu_vendor" in
    AuthenticAMD) CPU_UCODE=amd-ucode ;;
    GenuineIntel) CPU_UCODE=intel-ucode ;;
    *)
      CPU_UCODE=""
      echo "WARNING: unrecognized CPU vendor '${cpu_vendor}'; no microcode initrd will be configured." >&2
      ;;
  esac
fi
UCODE_INITRD_LINE=""
if [[ -n "$CPU_UCODE" ]]; then
  UCODE_INITRD_LINE="initrd /${CPU_UCODE}.img
"
fi

step 'Bootloader'
bootctl install
install -d -m 755 /boot/loader/entries
cat > /boot/loader/loader.conf <<LOADER
default arch.conf
timeout 2
editor no
LOADER
if [[ "$ENABLE_LUKS" == 1 ]]; then
  cat > /boot/loader/entries/arch.conf <<ENTRY
title Arch Linux
linux /vmlinuz-linux
${UCODE_INITRD_LINE}initrd /initramfs-linux.img
options cryptdevice=UUID=${LUKS_UUID}:${LUKS_NAME} root=/dev/mapper/${LUKS_NAME} rootflags=subvol=@ rw
ENTRY
  cat > /boot/loader/entries/arch-lts.conf <<ENTRY
title Arch Linux LTS
linux /vmlinuz-linux-lts
${UCODE_INITRD_LINE}initrd /initramfs-linux-lts.img
options cryptdevice=UUID=${LUKS_UUID}:${LUKS_NAME} root=/dev/mapper/${LUKS_NAME} rootflags=subvol=@ rw
ENTRY
else
  cat > /boot/loader/entries/arch.conf <<ENTRY
title Arch Linux
linux /vmlinuz-linux
${UCODE_INITRD_LINE}initrd /initramfs-linux.img
options root=UUID=${BTRFS_UUID} rootflags=subvol=@ rw
ENTRY
  cat > /boot/loader/entries/arch-lts.conf <<ENTRY
title Arch Linux LTS
linux /vmlinuz-linux-lts
${UCODE_INITRD_LINE}initrd /initramfs-linux-lts.img
options root=UUID=${BTRFS_UUID} rootflags=subvol=@ rw
ENTRY
fi

step 'Signed repository'
install -d -m 755 /etc/agentos
printf '%s\n' "$CHANNEL" > /etc/agentos/channel
# shellcheck disable=SC1091
source /root/release/repository.env
if [[ -n "$AGENTOS_LOCAL_REPO" && -d "$AGENTOS_LOCAL_REPO" ]]; then
  local_packages=()
  for package_name in agentos-base agentos-runtime agentos-shell; do
    mapfile -t matches < <(find "$AGENTOS_LOCAL_REPO" -maxdepth 1 -type f -name "${package_name}-*.pkg.tar.zst" ! -name '*-debug-*' | sort)
    (( ${#matches[@]} == 1 )) || { echo "embedded repository must contain exactly one $package_name package" >&2; exit 1; }
    local_packages+=("${matches[0]}")
  done
  pacman-key --add /root/release/agentos-signing.asc
  pacman-key --lsign-key "$AGENTOS_SIGNING_FINGERPRINT"
  pacman -U --noconfirm "${local_packages[@]}"
  # Keep the persistent update path HTTPS-only. If the install is offline,
  # leave the locally installed system usable and let first-boot configure it.
  if ! /root/agentos-repository.sh configure \
    "${AGENTOS_REPO_BASE_URL}/${CHANNEL}" \
    /root/release/agentos-signing.asc \
    "${AGENTOS_SIGNING_FINGERPRINT}"; then
    echo 'WARNING: embedded packages installed, but the remote update channel could not be configured.' >&2
    install -Dm644 /root/release/repository.env /etc/agentos/repository-pending.env
  fi
else
  /root/agentos-repository.sh configure \
    "${AGENTOS_REPO_BASE_URL}/${CHANNEL}" \
    /root/release/agentos-signing.asc \
    "${AGENTOS_SIGNING_FINGERPRINT}"
  pacman -Sy --noconfirm agentos-base agentos-runtime agentos-shell
fi

step 'Services'
systemctl enable NetworkManager sshd tailscaled smartd reflector.timer paccache.timer fstrim.timer ufw ollama
systemctl enable plasmalogin
systemctl set-default graphical.target
systemctl enable btrfs-scrub@-.timer
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0 to any port 22 proto tcp
ufw --force enable

step 'System policy'
WORKSTATION_USER="$USERNAME" AGENTOS_REPO="$AGENTOS_REPO" AGENTOS_CHANNEL="$CHANNEL" /root/apply-system-policy.sh /root

step 'Restic backup scaffold'
cat > /usr/local/bin/restic-backup <<RESTIC
#!/usr/bin/env bash
set -euo pipefail
set -a
source /etc/restic-backup.env
set +a
restic -r "\$RESTIC_REPOSITORY" backup /home /etc "/home/${USERNAME}/ops"
restic -r "\$RESTIC_REPOSITORY" forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
RESTIC
chmod +x /usr/local/bin/restic-backup
cat > /etc/systemd/system/restic-backup.service <<SERVICE
[Unit]
Description=Restic backup

[Service]
Type=oneshot
ExecStart=/usr/local/bin/restic-backup
SERVICE
cat > /etc/systemd/system/restic-backup.timer <<TIMER
[Unit]
Description=Daily restic backup

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
TIMER
cat > /etc/restic-backup.env.example <<ENV
RESTIC_REPOSITORY=rest:http://your-rest-server-or-s3-endpoint
RESTIC_PASSWORD_FILE=/etc/restic-backup.password
ENV

step 'Managed dotfiles seed'
install -d -m 755 "/home/${USERNAME}/.local/share/agentos"
cp -R /root/dotfiles "/home/${USERNAME}/.local/share/agentos/dotfiles"
if [[ ! -e "/home/${USERNAME}/.local/share/legacy-workstation" ]]; then
  ln -s agentos "/home/${USERNAME}/.local/share/legacy-workstation"
fi

step 'Optional developer-tool selection'
install -d -m 700 "/home/${USERNAME}/.config/agentos"
cat > "/home/${USERNAME}/.config/agentos/tooling.env" <<TOOLS
# Generated by the AgentOS installer. Edit these values before a later sync.
AGENTOS_INSTALL_OPENCODE=$INSTALL_OPENCODE
AGENTOS_IDE=$IDE
TOOLS
chmod 600 "/home/${USERNAME}/.config/agentos/tooling.env"

step 'Desktop'
install -d -m 755 "/home/${USERNAME}/.config/i3" "/home/${USERNAME}/.vnc" "/home/${USERNAME}/ops"
install -d -m 700 "/home/${USERNAME}/.local/share/agent-browser" "/home/${USERNAME}/.local/share/hermes-backups"
cat > "/home/${USERNAME}/.xinitrc" <<XINIT
exec dbus-run-session i3
XINIT
cat > "/home/${USERNAME}/.zprofile" <<'ZPROFILE'
# Plasma/Wayland is started by Plasma Login Manager. Keep tty and SSH shells
# usable; i3 remains available as the manual X11 troubleshooting fallback.
ZPROFILE
cat > "/home/${USERNAME}/.config/i3/config" <<I3
set \$mod Mod4
bindsym \$mod+Return exec kitty
bindsym \$mod+d exec dmenu_run
bindsym \$mod+Shift+q kill
bindsym \$mod+Shift+e exec i3-msg exit
I3
cat > "/home/${USERNAME}/.vnc/xstartup" <<VNC
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_ADDRESS
exec i3
VNC
chmod +x "/home/${USERNAME}/.vnc/xstartup"
cat > "/home/${USERNAME}/.vnc/config" <<VNCCONF
localhost
geometry=1920x1080
alwaysshared
VNCCONF

cat > "/home/${USERNAME}/ops/first-boot.md" <<NOTE
1. Log in on the console as ${USERNAME}; tty1 starts the i3 desktop automatically.
2. Run \`agentos welcome\` and review \`agentos config plan\`. Edit \`/etc/agentos/config.yaml\` before enabling optional capabilities or backups. Before \`sync-workstation\`, ensure the canonical AgentOS source is configured with \`AGENTOS_REPO\` or \`/etc/agentos/repository-url\`; a source URL is not guessed. Sync is the single explicit convergence/update command and applies the optional tool choices saved in \`~/.config/agentos/tooling.env\`.
   OpenCode: $INSTALL_OPENCODE; IDE: $IDE. Change that file to select OpenCode and at most one IDE: none, cursor, vscode, or webstorm.
3. Run \`tailscale up\` and join the tailnet.
4. Copy your SSH public key into \`/home/${USERNAME}/.ssh/authorized_keys\` if you did not pass SSH_PUBLIC_KEY.
5. Create \`/etc/restic-backup.env\` from \`/etc/restic-backup.env.example\` and add the password file, then enable \`restic-backup.timer\`.
6. If moving an existing Hermes setup from another machine, create a \`hermes backup\` there, copy the zip here, then run \`migrate-hermes <zip>\`. Stop the source gateway before \`enable-hermes-gateway\`.
7. For a new Hermes setup, run \`hermes setup\`, then \`enable-hermes-gateway\`. User lingering is preconfigured so the gateway can run after reboot without a graphical login.
8. Hermes quick backups run daily and full backups weekly under \`~/.local/share/hermes-backups\`. They are age-encrypted. Keep the corresponding private recovery key off this machine.
9. Run \`sudo workstation-doctor\` for consolidated health, or \`agentos support\` for a local redacted report. A daily timer sends actionable failures through the configured Hermes target when Hermes is available.
10. Weekly workstation automation only checks/reports available updates. It does not run pacman upgrades. View the latest report with \`workstation-maintenance-check --show\`.
11. Before explicit pacman transactions, a read-only root snapshot and matching /boot bundle are created. Use \`sudo rollback-workstation list\` and \`sudo rollback-workstation stage <snapshot>\` to stage a one-shot recovery boot.
12. If X needs to be started manually for troubleshooting, run \`startx\` only from a physical VT such as tty1, never from Kitty or SSH.
NOTE

cat > "/home/${USERNAME}/ops/recovery.md" <<'RECOVERY'
# Workstation recovery

## Roll back a package transaction while the machine still boots

1. `sudo rollback-workstation list`
2. Select a snapshot marked `boot-safe`.
3. `sudo rollback-workstation stage pre-pacman-YYYYMMDD-HHMMSS`
4. Reboot. Only that next boot uses the staged rollback.
5. Verify with `sudo rollback-workstation status` and `findmnt -no OPTIONS /`.
6. Reboot again to return to the normal default entry. The one-shot boot is already consumed.
7. Later use `sudo rollback-workstation cleanup` to prune old writable rollback roots.

The rollback command never overwrites the currently mounted root or the normal
`arch.conf` / `arch-lts.conf` entries. Each pre-pacman root snapshot has a
matching kernel/initrd bundle. Staging creates dedicated recovery entries and
uses `bootctl set-oneshot`, so a failed recovery attempt does not permanently
replace the normal boot path. A boot cleanup service removes consumed recovery
EFI artifacts after the machine is back on a normal root.

## Arch ISO / chroot recovery

1. Boot the Arch installer USB and unlock LUKS:
   `cryptsetup open /dev/nvme0n1p2 cryptroot`
2. Mount the root subvolume:
   `mount -o subvol=@ /dev/mapper/cryptroot /mnt`
3. Mount the EFI partition:
   `mount --mkdir /dev/nvme0n1p1 /mnt/boot`
4. Mount other Btrfs subvolumes as needed from `/etc/fstab`.
5. Enter the system: `arch-chroot /mnt`
6. Rebuild initramfs: `mkinitcpio -P`
7. Repair systemd-boot if needed: `bootctl install`
8. Inspect `/boot/loader/entries/arch.conf` and `arch-lts.conf`, then reboot.
RECOVERY

cat > "/home/${USERNAME}/ops/agent.service.example" <<AGENT
# Example systemd unit for a non-Hermes/custom always-on AI agent gateway.
[Unit]
Description=AI agent gateway
After=network-online.target ollama.service
Wants=network-online.target

[Service]
User=${USERNAME}
EnvironmentFile=/home/${USERNAME}/.agent/agent.env
WorkingDirectory=/home/${USERNAME}/.agent
ExecStart=/home/${USERNAME}/.agent/venv/bin/python -m agent gateway run
Restart=on-failure
RestartSec=5
MemoryHigh=8G
MemoryMax=12G
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
AGENT

chown -R "$USERNAME:$USERNAME" "/home/${USERNAME}/.config" "/home/${USERNAME}/.vnc" "/home/${USERNAME}/ops" "/home/${USERNAME}/.xinitrc" "/home/${USERNAME}/.zprofile" "/home/${USERNAME}/.local"

step 'Final notes'
echo 'Bootstrap complete.'
echo 'Review /home/'"$USERNAME"'/ops/first-boot.md before bringing the machine onto the network.'
