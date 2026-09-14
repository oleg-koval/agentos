#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_dir="${1:-$repo_root/out/repo/x86_64}"
package=("$repo_dir"/agentos-shell-*.pkg.tar.zst)
(( ${#package[@]} == 1 )) || { echo "Expected one agentos-shell package in $repo_dir." >&2; exit 1; }
test -f "${package[0]}"
mapfile -t runtime < <(find "$repo_dir" -maxdepth 1 -type f -name 'agentos-runtime-*.pkg.tar.zst' ! -name 'agentos-runtime-debug-*' | sort)
(( ${#runtime[@]} == 1 )) || { echo "Expected one agentos-runtime package in $repo_dir." >&2; exit 1; }
test -f "${runtime[0]}"

# CI packages are intentionally unsigned build outputs. Release workflow
# verifies signatures separately; this disposable install test only exercises
# pacman's file-conflict and install-script ordering in an isolated config.
pacman_config="$(mktemp)"
migration_tmp="$(mktemp -d)"
trap 'rm -f "$pacman_config"; rm -rf "$migration_tmp"' EXIT
cp /etc/pacman.conf "$pacman_config"
printf '\nSigLevel = Never\n' >> "$pacman_config"

install -Dm644 /dev/null /usr/share/wallpapers/AgentOS/wallpaper.svg
install -Dm644 /dev/null /usr/local/bin/unrelated-agent-tool
install -Dm755 /dev/null /usr/local/bin/btrfs-pre-pacman-snapshot
install -Dm755 /dev/null /usr/local/bin/btrfs-prune-pacman-snapshots
install -Dm755 /dev/null /usr/local/bin/agentos-native-event
install -Dm644 /dev/null /etc/pacman.d/hooks/95-btrfs-pre-pacman-snapshot.hook
install -Dm644 /dev/null /etc/pacman.d/hooks/96-btrfs-prune-pacman-snapshots.hook
for hook in /etc/pacman.d/hooks/95-btrfs-pre-pacman-snapshot.hook /etc/pacman.d/hooks/96-btrfs-prune-pacman-snapshots.hook; do
  printf '%s\n' '[Trigger]' 'Operation = Upgrade' 'Type = Package' 'Target = *' '' '[Action]' 'When = PostTransaction' "Exec = /usr/local/bin/$(basename "$hook" .hook | sed 's/^95-btrfs-pre-pacman-snapshot$/btrfs-pre-pacman-snapshot/;s/^96-btrfs-prune-pacman-snapshots$/btrfs-prune-pacman-snapshots/')" > "$hook"
done
pacman --config "$pacman_config" -Udd --noconfirm "${runtime[0]}" "${package[0]}"

pacman -Qo /usr/share/agentos/wallpaper.svg
[[ -e /usr/share/wallpapers/AgentOS/wallpaper.svg ]] || {
  echo 'Package hook ran a versioned wallpaper migration silently.' >&2
  exit 1
}
[[ -e /usr/local/bin/unrelated-agent-tool ]] || {
  echo 'Package migration removed an unrelated /usr/local file.' >&2
  exit 1
}
[[ ! -e /usr/local/bin/agentos-native-event ]] || {
  echo 'Known stale AgentOS native event adapter survived package migration.' >&2
  exit 1
}
[[ ! -e /etc/pacman.d/hooks/95-btrfs-pre-pacman-snapshot.hook ]]
[[ ! -e /etc/pacman.d/hooks/96-btrfs-prune-pacman-snapshots.hook ]]
pacman -Qo /usr/bin/btrfs-pre-pacman-snapshot
pacman -Qo /usr/lib/systemd/system/agentos-boot-health.service
pacman -Qo /usr/share/agentos/migrations/system/20260906-001-remove-legacy-wallpaper.sh
pacman -Qo /usr/share/agentos/migrations/system/20260906-002-clear-legacy-health-failure.sh
pacman -Qo /usr/share/agentos/migrations/system/20260907-001-expose-recovery-metadata.sh
pacman -Qo /usr/share/agentos/migrations/user/20260906-001-remove-legacy-shell-overrides.sh

fake_bin="$migration_tmp/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$fake_bin/systemctl"
PATH="$fake_bin:$PATH" AGENTOS_SYSTEM_MIGRATION_STATE="$migration_tmp/system-state" \
  agentos migrate apply --scope system --json >/dev/null
[[ ! -e /usr/share/wallpapers/AgentOS/wallpaper.svg ]] || {
  echo 'Versioned system migration did not remove the known legacy wallpaper.' >&2
  exit 1
}

user_home="$migration_tmp/home"
mkdir -p "$user_home/.config/systemd/user" "$user_home/.local/share/kwin/scripts/agentos-shell" "$user_home/.config/owner"
touch "$user_home/.config/systemd/user/agentos-home.service"
touch "$user_home/.config/systemd/user/agentos-ui@.service"
touch "$user_home/.local/share/kwin/scripts/agentos-shell/contents.js"
touch "$user_home/.config/owner/custom.conf"
HOME="$user_home" AGENTOS_USER_MIGRATION_STATE="$migration_tmp/user-state" \
  agentos migrate apply --scope user --json >/dev/null
[[ ! -e "$user_home/.config/systemd/user/agentos-home.service" ]]
[[ ! -e "$user_home/.config/systemd/user/agentos-ui@.service" ]]
[[ ! -e "$user_home/.local/share/kwin/scripts/agentos-shell" ]]
[[ -e "$user_home/.config/owner/custom.conf" ]]

echo 'AgentOS package install migration passed.'
