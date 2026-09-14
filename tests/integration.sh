#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "integration test failed: $*" >&2
  exit 1
}

assert_file() { [[ -f "$1" ]] || fail "missing file $1"; }
assert_not_file() { [[ ! -f "$1" ]] || fail "unexpected file $1"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }

# ---------------------------------------------------------------------------
# Rollback staging must use a dedicated one-shot entry and matching boot bundle.
# ---------------------------------------------------------------------------
rollback="$tmp/rollback"
snapshots="$rollback/snapshots"
top="$rollback/top"
boot="$rollback/boot"
state="$rollback/state"
mocks="$rollback/mocks"
name='pre-pacman-20260819-120000'
bundle="$snapshots/boot/$name"
mkdir -p "$snapshots/$name" "$bundle/loader/entries" "$top" "$boot/loader/entries" "$mocks"

cat > "$bundle/loader/entries/arch.conf" <<'EOF'
title Arch Linux
linux /vmlinuz-linux
initrd /cpu-ucode.img
initrd /initramfs-linux.img
options root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF
cat > "$bundle/loader/entries/arch-lts.conf" <<'EOF'
title Arch Linux LTS
linux /vmlinuz-linux-lts
initrd /cpu-ucode.img
initrd /initramfs-linux-lts.img
options root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF
for artifact in vmlinuz-linux vmlinuz-linux-lts cpu-ucode.img initramfs-linux.img initramfs-linux-lts.img; do
  printf 'fixture:%s\n' "$artifact" > "$bundle/$artifact"
done
(
  cd "$bundle"
  find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256
)

cat > "$boot/loader/entries/arch.conf" <<'EOF'
title NORMAL ARCH ENTRY
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF
cp "$boot/loader/entries/arch.conf" "$rollback/normal-before.conf"

cat > "$mocks/btrfs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  'subvolume show') exit 0 ;;
  'subvolume snapshot')
    mkdir -p "$4"
    printf 'mock rollback root\n' > "$4/.mock-subvolume"
    ;;
  'subvolume delete') rm -rf "$3" ;;
  *) echo "unexpected btrfs invocation: $*" >&2; exit 1 ;;
esac
EOF
cat > "$mocks/bootctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BOOTCTL_LOG"
EOF
cat > "$mocks/findmnt" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *OPTIONS* ]]; then
  echo 'rw,relatime,subvol=/@'
else
  echo '/dev/mapper/cryptroot'
fi
EOF
chmod +x "$mocks"/*

BOOTCTL_LOG="$rollback/bootctl.log" \
BTRFS_SNAPSHOT_DIR="$snapshots" \
BTRFS_TOP_LEVEL_DIR="$top" \
BOOT_ROOT="$boot" \
WORKSTATION_STATE_DIR="$state" \
PATH="$mocks:/usr/bin:/bin" \
  bash "$repo_root/rollback-workstation.sh" stage "$name"

cmp -s "$rollback/normal-before.conf" "$boot/loader/entries/arch.conf" \
  || fail 'normal arch.conf was modified during rollback staging'
assert_file "$boot/loader/entries/agentos-rollback.conf"
assert_contains "$boot/loader/entries/agentos-rollback.conf" 'rootflags=subvol=@rollback-'
assert_contains "$boot/loader/entries/agentos-rollback.conf" '/agentos-rollback/@rollback-'
assert_contains "$rollback/bootctl.log" 'set-oneshot agentos-rollback.conf'

BOOTCTL_LOG="$rollback/bootctl.log" \
BTRFS_SNAPSHOT_DIR="$snapshots" \
BTRFS_TOP_LEVEL_DIR="$top" \
BOOT_ROOT="$boot" \
WORKSTATION_STATE_DIR="$state" \
PATH="$mocks:/usr/bin:/bin" \
  bash "$repo_root/rollback-workstation.sh" cancel
assert_not_file "$boot/loader/entries/agentos-rollback.conf"
assert_contains "$rollback/bootctl.log" 'set-oneshot arch.conf'

# Stage again after removing the test-only writable root, then simulate the
# normal boot that follows a consumed/failed one-shot. Boot cleanup must remove
# recovery EFI state without touching arch.conf or scheduling another one-shot.
rm -rf "$top"/@rollback-*
: > "$rollback/bootctl-cleanup.log"
BOOTCTL_LOG="$rollback/bootctl-cleanup.log" \
BTRFS_SNAPSHOT_DIR="$snapshots" \
BTRFS_TOP_LEVEL_DIR="$top" \
BOOT_ROOT="$boot" \
WORKSTATION_STATE_DIR="$state" \
PATH="$mocks:/usr/bin:/bin" \
  bash "$repo_root/rollback-workstation.sh" stage "$name"
assert_file "$state/rollback.env"
assert_file "$boot/loader/entries/agentos-rollback.conf"

BOOTCTL_LOG="$rollback/bootctl-cleanup.log" \
WORKSTATION_ROLLBACK_STATE="$state/rollback.env" \
BOOT_ROOT="$boot" \
PATH="$mocks:/usr/bin:/bin" \
  bash "$repo_root/rollback-boot-cleanup.sh"
assert_not_file "$state/rollback.env"
assert_not_file "$boot/loader/entries/agentos-rollback.conf"
cmp -s "$rollback/normal-before.conf" "$boot/loader/entries/arch.conf" \
  || fail 'normal arch.conf was modified during consumed rollback cleanup'
[[ "$(grep -c 'set-oneshot' "$rollback/bootctl-cleanup.log")" -eq 1 ]] \
  || fail 'rollback cleanup scheduled an unexpected additional one-shot'

# ---------------------------------------------------------------------------
# Hermes backups must end encrypted and leave no plaintext archive in the vault.
# ---------------------------------------------------------------------------
backup="$tmp/hermes"
home="$backup/home"
runtime="$backup/runtime"
mkdir -p "$home/.hermes" "$home/.ssh" "$home/.local/bin" "$runtime"
printf 'ssh-ed25519 AAAATESTKEY workstation-test\n' > "$home/.ssh/authorized_keys"

cat > "$home/.local/bin/hermes" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=''
while [[ $# -gt 0 ]]; do
  if [[ "$1" == '-o' ]]; then out="$2"; shift 2; else shift; fi
done
[[ -n "$out" ]]
printf 'mock hermes zip\n' > "$out"
EOF
cat > "$home/.local/bin/age" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=''
in=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -R) shift 2 ;;
    -o) out="$2"; shift 2 ;;
    *) in="$1"; shift ;;
  esac
done
[[ -n "$out" && -n "$in" ]]
cp "$in" "$out"
EOF
chmod +x "$home/.local/bin/hermes" "$home/.local/bin/age"
chmod 755 "$tmp" "$backup" "$runtime"
chown -R nobody:nobody "$home" "$runtime"

runuser -u nobody -- env HOME="$home" XDG_RUNTIME_DIR="$runtime" \
  bash "$repo_root/hermes-backup.sh" --quick

shopt -s nullglob
encrypted=("$home/.local/share/hermes-backups"/hermes-quick-*.zip.age)
plaintext=("$home/.local/share/hermes-backups"/hermes-quick-*.zip)
shopt -u nullglob
(( ${#encrypted[@]} == 1 )) || fail 'expected exactly one encrypted Hermes backup'
(( ${#plaintext[@]} == 0 )) || fail 'plaintext Hermes backup remained in the vault'
assert_file "$home/.config/agentos/hermes-backup-recipients.txt"

echo 'Integration validation passed.'
