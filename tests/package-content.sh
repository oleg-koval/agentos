#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
input="${1:-$repo_root/out/repo}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [[ -d "$input" ]]; then
  mapfile -t packages < <(find "$input" -maxdepth 1 -type f -name 'agentos-*.pkg.tar.zst' ! -name '*-debug-*' | sort)
else
  packages=("$@")
fi
(( ${#packages[@]} > 0 )) || { echo "No AgentOS packages found in $input." >&2; exit 1; }

runtime=''
shell=''
keyring=''
for package in "${packages[@]}"; do
  [[ -f "$package" ]] || { echo "Package not found: $package" >&2; exit 1; }
  case "$(basename "$package")" in
    agentos-runtime-*.pkg.tar.zst) runtime="$package" ;;
    agentos-shell-*.pkg.tar.zst) shell="$package" ;;
    agentos-keyring-*.pkg.tar.zst) keyring="$package" ;;
  esac
done
[[ -n "$runtime" ]] || { echo 'agentos-runtime package is missing.' >&2; exit 1; }
[[ -n "$shell" ]] || { echo 'agentos-shell package is missing.' >&2; exit 1; }
[[ -n "$keyring" ]] || { echo 'agentos-keyring package is missing.' >&2; exit 1; }

extract() {
  local package="$1" name="$2"
  mkdir -p "$tmp/$name"
  bsdtar -xf "$package" -C "$tmp/$name"
}
assert_files() {
  local root="$1"; shift
  local path
  for path in "$@"; do
    [[ -e "$root$path" ]] || { echo "Missing package file: $path" >&2; exit 1; }
  done
}
assert_executable() {
  local root="$1"; shift
  local path
  for path in "$@"; do
    [[ -x "$root$path" ]] || { echo "Package file is not executable: $path" >&2; exit 1; }
  done
}

extract "$runtime" runtime
extract "$shell" shell
extract "$keyring" keyring
runtime_root="$tmp/runtime"
shell_root="$tmp/shell"
keyring_root="$tmp/keyring"

runtime_files=(
  /usr/bin/agentos
  /usr/bin/install-agent-tools
  /usr/bin/agentos-ops
  /usr/bin/agentos-config
  /usr/bin/agentosd
  /usr/bin/agentos-agent-event
  /usr/bin/agentos-native-event
  /usr/bin/agentos-herdr-bridge
  /usr/bin/agentos-transaction
  /usr/bin/agentos-boot-health
  /usr/bin/agentos-repository
  /usr/bin/agentos-onboarding
  /usr/bin/agentos-vps-install
  /usr/bin/agentos-power-policy
  /usr/lib/agentos/agentos-migrate-notify
  /usr/lib/agentos/agentos-update-notify
  /usr/bin/workstation-doctor
  /usr/bin/workstation-maintenance-check
  /usr/bin/rollback-boot-cleanup
  /usr/bin/hermes-backup
  /usr/bin/restic-verify
  /usr/bin/rollback-workstation
  /usr/bin/btrfs-pre-pacman-snapshot
  /usr/bin/btrfs-prune-pacman-snapshots
  /usr/bin/agentos-support
  /usr/bin/agentos-telemetry
  /usr/lib/agentos/agentos-weekly-update \
  /usr/lib/agentos/ensure-repository-config \
  /usr/lib/agentos/ensure-agentos-config
  /usr/lib/systemd/user/agentosd.service
  /usr/lib/systemd/user/agentos-herdr-bridge.service
  /usr/lib/systemd/user/agentos-migrate-notify.service
  /usr/lib/systemd/user/agentos-update-notify.service
  /usr/lib/systemd/user/agentos-update-notify.timer
  /usr/lib/systemd/system/agentos-boot-health.service
  /usr/lib/systemd/system/agentos-weekly-update.service
  /usr/lib/systemd/system/agentos-weekly-update.timer
  /usr/lib/systemd/system/workstation-maintenance-check.service
  /usr/lib/systemd/system/workstation-maintenance-check.timer
  /usr/lib/systemd/system/workstation-health-check.service
  /usr/lib/systemd/system/workstation-health-check.timer
  /usr/lib/systemd/system/workstation-rollback-cleanup.service
  /usr/lib/systemd/system/restic-verify.service
  /usr/lib/systemd/system/restic-verify.timer
  /usr/lib/systemd/user/hermes-backup-quick.service
  /usr/lib/systemd/user/hermes-backup-quick.timer
  /usr/lib/systemd/user/hermes-backup-full.service
  /usr/lib/systemd/user/hermes-backup-full.timer
  /usr/share/libalpm/hooks/95-btrfs-pre-pacman-snapshot.hook
  /usr/share/libalpm/hooks/96-btrfs-prune-pacman-snapshots.hook
  /usr/share/libalpm/hooks/99-agentos-repository-persistence.hook
  /usr/share/agentos/registry/capabilities.json
  /usr/share/agentos/migrations/system/20260906-001-remove-legacy-wallpaper.sh
  /usr/share/agentos/migrations/system/20260906-002-clear-legacy-health-failure.sh
  /usr/share/agentos/migrations/system/20260907-001-expose-recovery-metadata.sh
  /usr/share/agentos/migrations/user/20260906-001-remove-legacy-shell-overrides.sh
  /usr/share/agentos/AGENTS.md
  /usr/share/agentos/config.yaml.example
  /usr/share/agentos/channels/stable.json
  /usr/share/agentos/channels/beta.json
  /usr/share/agentos/channels/edge.json
  /usr/share/agentos/skills/agentos-operator/SKILL.md
  /usr/share/agentos/skills/agentos-maintainer/SKILL.md
  /usr/share/agentos/skills/agentos-system/SKILL.md
  /usr/share/doc/agentos/help.md
  /usr/share/doc/agentos/troubleshooting.md
  /usr/share/doc/agentos/friend-system-acceptance.md
  /usr/share/doc/agentos/vps-onboarding.md
  /usr/share/doc/agentos/vps-providers.md
)
shell_files=(
  /usr/bin/agentos-home
  /usr/bin/agentos-ui
  /usr/bin/agentos-shell
  /usr/bin/agentos-desktop
  /usr/bin/agentos-native-workspace
  /usr/share/agentos/native-shell/Main.qml
  /usr/share/applications/agentos-native-workspace.desktop
  /usr/share/applications/agentos-help.desktop
  /usr/share/color-schemes/AgentOS.colors
  /usr/share/agentos/wallpaper.svg
  /usr/share/plasma/plasmoids/com.agentos.status/metadata.json
  /usr/share/plasma/plasmoids/com.agentos.status/contents/ui/main.qml
  /usr/lib/systemd/user/agentos-home.service
  /usr/lib/systemd/user/agentos-native-workspace.service
  /usr/lib/systemd/user/agentos-ui@.service
  /usr/share/kwin/scripts/agentos-shell/metadata.json
  /usr/share/kwin/scripts/agentos-shell/contents/code/main.js
)
assert_files "$runtime_root" "${runtime_files[@]}"
assert_files "$shell_root" "${shell_files[@]}"
assert_executable "$runtime_root" \
  /usr/bin/agentos /usr/bin/agentos-ops /usr/bin/agentos-config /usr/bin/agentosd /usr/bin/agentos-agent-event \
  /usr/bin/install-agent-tools \
  /usr/bin/agentos-native-event \
  /usr/bin/agentos-herdr-bridge /usr/bin/agentos-transaction /usr/bin/agentos-boot-health \
  /usr/bin/agentos-repository /usr/bin/agentos-onboarding /usr/bin/agentos-vps-install /usr/bin/agentos-power-policy /usr/bin/workstation-doctor /usr/bin/rollback-workstation \
  /usr/bin/btrfs-pre-pacman-snapshot /usr/bin/btrfs-prune-pacman-snapshots \
  /usr/bin/workstation-maintenance-check /usr/bin/rollback-boot-cleanup \
  /usr/bin/hermes-backup /usr/bin/restic-verify \
  /usr/lib/agentos/agentos-weekly-update \
  /usr/lib/agentos/ensure-repository-config \
  /usr/lib/agentos/ensure-agentos-config \
  /usr/lib/agentos/agentos-migrate-notify \
  /usr/lib/agentos/agentos-update-notify
assert_executable "$shell_root" /usr/bin/agentos-home /usr/bin/agentos-ui /usr/bin/agentos-shell /usr/bin/agentos-desktop /usr/bin/agentos-native-workspace

grep -Fqx 'ExecStart=/usr/bin/agentos-boot-health check' "$runtime_root/usr/lib/systemd/system/agentos-boot-health.service"
grep -Fqx 'Environment=PATH=%h/.local/bin:/usr/bin' "$runtime_root/usr/lib/systemd/user/agentosd.service"
grep -Fqx 'Environment=PATH=%h/.local/bin:/usr/bin' "$runtime_root/usr/lib/systemd/user/agentos-herdr-bridge.service"
grep -Fqx 'ExecStart=/usr/lib/agentos/agentos-migrate-notify' "$runtime_root/usr/lib/systemd/user/agentos-migrate-notify.service"
grep -Fqx 'ExecStart=/usr/lib/agentos/agentos-update-notify' "$runtime_root/usr/lib/systemd/user/agentos-update-notify.service"
grep -Fqx 'Unit=agentos-update-notify.service' "$runtime_root/usr/lib/systemd/user/agentos-update-notify.timer"
grep -Fqx 'ExecStart=/usr/lib/agentos/agentos-weekly-update --scheduled' "$runtime_root/usr/lib/systemd/system/agentos-weekly-update.service"
grep -Fqx 'ExecStart=/usr/bin/workstation-doctor --notify' "$runtime_root/usr/lib/systemd/system/workstation-health-check.service"
grep -Fqx 'ExecStart=/usr/bin/hermes-backup --quick' "$runtime_root/usr/lib/systemd/user/hermes-backup-quick.service"
grep -Fqx 'Exec = /usr/bin/btrfs-pre-pacman-snapshot' "$runtime_root/usr/share/libalpm/hooks/95-btrfs-pre-pacman-snapshot.hook"
grep -Fqx 'Exec = /usr/bin/btrfs-prune-pacman-snapshots' "$runtime_root/usr/share/libalpm/hooks/96-btrfs-prune-pacman-snapshots.hook"
grep -Fqx 'Exec = /usr/lib/agentos/ensure-repository-config' "$runtime_root/usr/share/libalpm/hooks/99-agentos-repository-persistence.hook"
! grep -R -Fq '/usr/local' "$runtime_root/usr/lib/systemd" "$runtime_root/usr/share/libalpm/hooks"
! grep -R -Fq '/usr/local' "$shell_root/usr/lib/systemd"
grep -Fq 'pkgname = agentos-runtime' "$runtime_root/.PKGINFO"
grep -Fq 'depend = libnotify' "$runtime_root/.PKGINFO"
grep -Fq 'pkgname = agentos-shell' "$shell_root/.PKGINFO"
grep -Fq 'pkgname = agentos-keyring' "$keyring_root/.PKGINFO"
assert_files "$keyring_root" /usr/share/agentos/agentos-signing.asc
grep -Fq 'BEGIN PGP PUBLIC KEY BLOCK' "$keyring_root/usr/share/agentos/agentos-signing.asc"
# The key is only a trust anchor once pacman has imported it, so the package
# must re-import on install and on every upgrade that ships a rotated key.
grep -Fq 'pacman-key --add' "$repo_root/packages/agentos-keyring/agentos-keyring.install"
grep -Fq 'post_install()' "$repo_root/packages/agentos-keyring/agentos-keyring.install"
grep -Fq 'post_upgrade()' "$repo_root/packages/agentos-keyring/agentos-keyring.install"
grep -Fq 'name: agentos-observability' "$runtime_root/usr/share/agentos/hermes-plugin/plugin.yaml"
grep -Fq '"schema": "agentos.tools/v1"' "$runtime_root/usr/share/agentos/tool-versions.json"
grep -Fq 'name: agentos-operator' "$runtime_root/usr/share/agentos/skills/agentos-operator/SKILL.md"
grep -Fq 'name: agentos-maintainer' "$runtime_root/usr/share/agentos/skills/agentos-maintainer/SKILL.md"
grep -Fq 'AgentOS' "$runtime_root/usr/share/agentos/AGENTS.md"
grep -Fq 'A clean source test or CI run must never' "$runtime_root/usr/share/doc/agentos/friend-system-acceptance.md"
grep -Fq 'Hardware readiness' "$shell_root/usr/share/agentos/native-shell/Main.qml"
grep -Fq 'Recovery Center' "$shell_root/usr/share/agentos/native-shell/Main.qml"
grep -Fq 'Support & privacy' "$shell_root/usr/share/agentos/native-shell/Main.qml"
grep -Fq 'Hardware readiness' "$shell_root/usr/bin/agentos-home"
grep -Fq 'Recovery Center' "$shell_root/usr/bin/agentos-home"
grep -Fq 'Support &amp; privacy' "$shell_root/usr/bin/agentos-home"
grep -Fq 'agentos-system' "$runtime_root/usr/share/agentos/skills/agentos-system/SKILL.md"

echo 'AgentOS package content contract passed.'
