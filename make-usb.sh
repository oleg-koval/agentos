#!/usr/bin/env bash
# Download the latest Arch Linux ISO and write it to a USB drive.
# Run this on macOS, on the machine you'll use to build the installer USB.
set -euo pipefail

MIRROR="${MIRROR:-https://geo.mirror.pkgbuild.com/iso/latest}"
ISO_NAME="archlinux-x86_64.iso"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/agentos}"
ISO_PATH="$CACHE_DIR/$ISO_NAME"
DISK="${DISK:-}"

step() {
  printf '\n==> %s\n' "$1"
}

need_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || { echo 'This script is for macOS.' >&2; exit 1; }
}

download_iso() {
  step 'Download Arch ISO'
  mkdir -p "$CACHE_DIR"
  curl -fL --progress-bar -o "$ISO_PATH" "$MIRROR/$ISO_NAME"
  curl -fsSL -o "$CACHE_DIR/sha256sums.txt" "$MIRROR/sha256sums.txt"
}

verify_iso() {
  step 'Verify checksum'
  local expected actual
  expected="$(grep " $ISO_NAME\$" "$CACHE_DIR/sha256sums.txt" | awk '{print $1}')"
  actual="$(shasum -a 256 "$ISO_PATH" | awk '{print $1}')"
  [[ -n "$expected" && "$expected" == "$actual" ]] || { echo 'Checksum mismatch, aborting.' >&2; exit 1; }
  echo 'Checksum OK.'
}

pick_disk() {
  step 'External disks'
  diskutil list external physical
  if [[ -z "$DISK" ]]; then
    printf 'Enter target disk (e.g. disk4): '
    read -r DISK
  fi
  DISK="/dev/${DISK#/dev/}"
  [[ "$DISK" =~ ^/dev/disk[0-9]+$ ]] || { echo "Not a whole-disk identifier: $DISK" >&2; exit 1; }
  if ! diskutil list external physical | awk -v disk="${DISK#/dev/}" '$NF == disk { found = 1 } END { exit !found }'; then
    echo "$DISK is not an external physical disk. Refusing to write it." >&2
    exit 1
  fi
}

confirm() {
  printf 'This will ERASE ALL DATA on %s. Type YES to continue: ' "$DISK"
  read -r answer
  [[ "$answer" == "YES" ]]
}

write_usb() {
  step 'Write USB'
  diskutil unmountDisk "$DISK"
  local rdisk="/dev/r${DISK#/dev/}"
  echo "Writing $ISO_PATH to $rdisk (press Ctrl+T for progress)..."
  sudo dd if="$ISO_PATH" of="$rdisk" bs=4m
  diskutil eject "$DISK"
}

main() {
  need_macos
  download_iso
  verify_iso
  pick_disk
  confirm
  write_usb
  step 'Done'
  echo 'Boot the target machine from this USB, plug in ethernet, then follow README.md.'
}

main "$@"
