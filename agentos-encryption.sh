#!/usr/bin/env bash
# Manage AgentOS encrypted-root remote operability.
# Provisioning is safe/idempotent; TPM enrollment remains an explicit action.
set -euo pipefail

ACTION="${1:---status}"
shift || true

[[ ${EUID} -ne 0 ]] || { echo 'Run agentos-encryption as the workstation user; it uses sudo where required.' >&2; exit 1; }

resolve_luks_device() {
  local source block resolved parent dm_name slave candidate status_device

  # With Btrfs subvolumes findmnt commonly returns e.g.
  # /dev/mapper/cryptroot[/@]. Strip the bracketed fsroot before treating it as
  # a block-device path.
  source="$(findmnt -no SOURCE / 2>/dev/null || true)"
  block="${source%%\[*}"
  [[ "$block" == /dev/* ]] || return 1

  resolved="$(readlink -f "$block" 2>/dev/null || printf '%s' "$block")"

  # Most reliable path for an already-open dm-crypt mapping: ask cryptsetup
  # which physical device backs the mapping. This avoids lsblk/sysfs differences
  # across Btrfs, device-mapper and util-linux versions.
  if [[ "$block" == /dev/mapper/* ]]; then
    dm_name="${block#/dev/mapper/}"
    status_device="$(sudo cryptsetup status "$dm_name" 2>/dev/null | sed -n 's/^[[:space:]]*device:[[:space:]]*//p' | head -1 || true)"
    if [[ -n "$status_device" ]]; then
      candidate="$(readlink -f "$status_device" 2>/dev/null || printf '%s' "$status_device")"
      if sudo cryptsetup isLuks "$candidate" >/dev/null 2>&1; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  fi

  # Normal dm-crypt path. lsblk may resolve the active mapper to the physical
  # LUKS partition directly.
  parent="$(lsblk -ndo PKNAME "$block" 2>/dev/null | head -1 || true)"
  if [[ -z "$parent" && "$resolved" != "$block" ]]; then
    parent="$(lsblk -ndo PKNAME "$resolved" 2>/dev/null | head -1 || true)"
  fi
  if [[ -n "$parent" ]]; then
    candidate="/dev/$parent"
    if sudo cryptsetup isLuks "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  # Fallback through the resolved /dev/dm-N sysfs node. Mapper names are not
  # necessarily present directly under /sys/class/block, but readlink -f turns
  # /dev/mapper/cryptroot into /dev/dm-N which is.
  dm_name="$(basename "$resolved")"
  if [[ -d "/sys/class/block/$dm_name/slaves" ]]; then
    slave="$(find "/sys/class/block/$dm_name/slaves" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | head -1 || true)"
    if [[ -n "$slave" ]]; then
      candidate="/dev/$slave"
      if sudo cryptsetup isLuks "$candidate" >/dev/null 2>&1; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  fi

  return 1
}

root_source="$(findmnt -no SOURCE / 2>/dev/null || true)"
luks_device="$(resolve_luks_device || true)"
if [[ -z "$luks_device" ]]; then
  echo "Could not resolve the LUKS device backing /. Root source was: ${root_source:-unknown}" >&2
  echo 'Aborting without changes.' >&2
  echo 'Diagnostic commands:' >&2
  echo '  findmnt -no SOURCE /' >&2
  echo '  sudo cryptsetup status cryptroot' >&2
  echo '  lsblk -o NAME,TYPE,FSTYPE,PKNAME,MOUNTPOINTS' >&2
  exit 1
fi
luks_uuid="$(sudo cryptsetup luksUUID "$luks_device")"

status() {
  echo "Root source: $root_source"
  echo "LUKS device: $luks_device"
  echo "LUKS UUID:   $luks_uuid"
  printf 'TPM2:        '
  if systemd-cryptenroll --tpm2-device=list 2>/dev/null | grep -q '/dev/tpm'; then echo available; else echo unavailable; fi
  printf 'TPM token:   '
  if sudo cryptsetup luksDump "$luks_device" 2>/dev/null | grep -q 'systemd-tpm2'; then echo enrolled; else echo not-enrolled; fi
  printf 'Initramfs:   '
  grep -q 'sd-encrypt' /etc/mkinitcpio.conf 2>/dev/null && echo systemd/sd-encrypt || echo legacy-or-other
  printf 'Remote SSH:  '
  if systemctl is-enabled initrd-tinysshd.service >/dev/null 2>&1; then echo provisioned; else echo not-provisioned; fi
}

backup_boot_config() {
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="/var/lib/agentos/encryption-backups/$stamp"
  sudo install -d -m 700 "$dir"
  sudo cp -a /etc/mkinitcpio.conf "$dir/"
  [[ -f /etc/crypttab.initramfs ]] && sudo cp -a /etc/crypttab.initramfs "$dir/" || true
  sudo cp -a /boot/loader/entries "$dir/loader-entries"
  echo "Boot configuration backup: $dir"
}

ensure_systemd_initramfs() {
  backup_boot_config
  sudo pacman -S --needed --noconfirm tpm2-tss mkinitcpio-systemd-tool tinyssh busybox
  # Migrate the known AgentOS legacy hook set to systemd. Preserve MODULES and
  # other mkinitcpio settings; only replace HOOKS.
  sudo sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt systemd-tool filesystems fsck)/' /etc/mkinitcpio.conf
  printf 'cryptroot UUID=%s none tpm2-device=auto,password-echo=no\n' "$luks_uuid" \
    | sudo tee /etc/crypttab.initramfs >/dev/null
  # systemd's generator uses rd.luks.* rather than the legacy cryptdevice= syntax.
  for entry in /boot/loader/entries/arch.conf /boot/loader/entries/arch-lts.conf; do
    [[ -f "$entry" ]] || continue
    sudo sed -E -i \
      "s#options .*root=/dev/mapper/[^ ]+ rootflags=subvol=@ rw#options rd.luks.name=${luks_uuid}=cryptroot rd.luks.options=${luks_uuid}=tpm2-device=auto,password-echo=no root=/dev/mapper/cryptroot rootflags=subvol=@ rw#" \
      "$entry"
  done
}

enable_tpm() {
  echo 'This adds a TPM2 keyslot. Your existing LUKS passphrase remains valid as recovery.'
  systemd-cryptenroll --tpm2-device=list
  ensure_systemd_initramfs
  # PCR 7 binds automatic unlock to Secure Boot state. If Secure Boot is currently
  # disabled, the token is still tied to that measured state and may need
  # re-enrollment when Secure Boot is enabled later.
  sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 "$luks_device"
  sudo mkinitcpio -P
  echo 'TPM2 enrollment complete. Do NOT remove the passphrase keyslot.'
  echo 'Before remote reboot, verify: agentos-encryption --status'
}

enable_remote_unlock() {
  key="${1:-$HOME/.ssh/id_ed25519.pub}"
  [[ -r "$key" ]] || { echo "Public key not found: $key" >&2; echo 'Usage: agentos-encryption --enable-remote-unlock /path/to/id_ed25519.pub' >&2; exit 1; }
  ensure_systemd_initramfs
  sudo install -d -m 700 /etc/mkinitcpio-systemd-tool/config
  sudo install -m 600 "$key" /etc/mkinitcpio-systemd-tool/config/authorized_keys
  # The packaged systemd-tool provides initrd networking, tinysshd and the
  # cryptsetup password-agent shell. Enable these units so the hook embeds them.
  sudo systemctl enable initrd-network.service initrd-tinysshd.service initrd-cryptsetup.path initrd-shell.service
  sudo mkinitcpio -P
  echo 'Initramfs SSH unlock provisioned with key:' "$key"
  echo 'Important: initramfs runs before Tailscale. Connect over the LAN address, not the Tailscale 100.x address.'
  echo 'Test this only while you have physical-console access available.'
}

case "$ACTION" in
  --status) status ;;
  --prepare) ensure_systemd_initramfs; sudo mkinitcpio -P; status ;;
  --enable-tpm) enable_tpm; status ;;
  --enable-remote-unlock) enable_remote_unlock "${1:-}"; status ;;
  *) echo 'Usage: agentos-encryption [--status|--prepare|--enable-tpm|--enable-remote-unlock [public-key]]' >&2; exit 2 ;;
esac
