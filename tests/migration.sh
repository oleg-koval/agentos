#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="$tmp/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/gpg" <<'EOF'
#!/usr/bin/env bash
printf 'fpr:::::::::3060184CFC884D14CB1D54F9CA25144B4E4DBA8E:\n'
EOF
cat > "$fake_bin/pacman-key" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$fake_bin/pacman" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$fake_bin"/*

conf="$tmp/pacman.conf"
include="$tmp/pacman.d/agentos.conf"
state="$tmp/state"
cat > "$conf" <<'EOF'
[core]
Include = /etc/pacman.d/mirrorlist

# BEGIN AGENTOS REPOSITORY
[agentos]
SigLevel = Required
Server = https://old.invalid/$arch
# END AGENTOS REPOSITORY

[agentos]
SigLevel = Optional TrustAll
Server = https://duplicate.invalid/$arch

[extra]
Include = /etc/pacman.d/mirrorlist
EOF
key="$tmp/public.asc"
touch "$key"

PATH="$fake_bin:$PATH" AGENTOS_REPOSITORY_TEST_MODE=1 PACMAN_CONF="$conf" AGENTOS_PACMAN_INCLUDE="$include" AGENTOS_STATE_DIR="$state" PACMAN_KEYRING="$tmp/keyring" \
  bash "$repo_root/agentos-repository.sh" configure \
  'https://example.invalid/agentos/$arch' "$key" 3060184CFC884D14CB1D54F9CA25144B4E4DBA8E

[[ "$(grep -c '^\[agentos\]$' "$conf")" -eq 0 ]]
[[ "$(grep -c '^Include = '"$include"'$' "$conf")" -eq 1 ]]
grep -Fqx '[agentos]' "$include"
grep -Fqx 'SigLevel = Required' "$include"
grep -Fqx 'Server = https://example.invalid/agentos/$arch' "$include"
jq -e '.schema == "agentos.repository/v1" and .fingerprint == "3060184CFC884D14CB1D54F9CA25144B4E4DBA8E"' "$state/repository.json" >/dev/null

awk '$0 !~ /^Include = .*agentos.conf$/' "$conf" > "$conf.tmp"
mv "$conf.tmp" "$conf"
rm -f "$include"
PATH="$fake_bin:$PATH" AGENTOS_REPOSITORY_TEST_MODE=1 PACMAN_CONF="$conf" AGENTOS_PACMAN_INCLUDE="$include" AGENTOS_STATE_DIR="$state" PACMAN_KEYRING="$tmp/keyring" \
  bash "$repo_root/agentos-repository.sh" repair
[[ "$(grep -c '^Include = '"$include"'$' "$conf")" -eq 1 ]]
[[ -f "$include" ]]

migration_root="$tmp/migration-root"
for path in \
  /usr/local/bin/agentos /usr/local/bin/agentosd /usr/local/bin/agentos-agent-event \
  /usr/local/bin/agentos-herdr-bridge /usr/local/bin/agentos-transaction \
  /usr/local/bin/agentos-repository /usr/local/bin/agentos-support \
  /usr/local/bin/agentos-telemetry /usr/local/bin/workstation-doctor \
  /usr/local/bin/workstation-maintenance-check /usr/local/bin/rollback-boot-cleanup \
  /usr/local/bin/hermes-backup /usr/local/bin/restic-verify \
  /usr/local/sbin/agentos-boot-health /etc/systemd/user/agentosd.service \
  /etc/systemd/system/agentos-boot-health.service /etc/systemd/system/workstation-health-check.service \
  /etc/systemd/user/hermes-backup-quick.service /etc/pacman.d/hooks/95-btrfs-pre-pacman-snapshot.hook; do
  mkdir -p "$migration_root$(dirname "$path")"
  touch "$migration_root$path"
done
mkdir -p "$migration_root/usr/local/bin"
touch "$migration_root/usr/local/bin/unrelated-tool"
AGENTOS_MIGRATION_ROOT="$migration_root" bash -c 'source "$1"; pre_install' _ "$repo_root/packages/agentos-runtime/agentos-runtime.install"
[[ ! -e "$migration_root/usr/local/bin/agentos" ]]
[[ ! -e "$migration_root/usr/local/bin/agentos-support" ]]
[[ ! -e "$migration_root/usr/local/bin/agentos-telemetry" ]]
[[ ! -e "$migration_root/etc/systemd/system/agentos-boot-health.service" ]]
[[ ! -e "$migration_root/etc/systemd/system/workstation-health-check.service" ]]
[[ -e "$migration_root/usr/local/bin/unrelated-tool" ]]

mkdir -p "$migration_root/usr/share/wallpapers/AgentOS"
touch "$migration_root/usr/share/wallpapers/AgentOS/wallpaper.svg"
mkdir -p "$migration_root/home/admin/.config/systemd/user"
mkdir -p "$migration_root/home/admin/.local/share/kwin/scripts/agentos-shell"
touch "$migration_root/home/admin/.config/systemd/user/agentos-home.service"
touch "$migration_root/home/admin/.config/systemd/user/agentos-ui@.service"
touch "$migration_root/home/admin/.local/share/kwin/scripts/agentos-shell/contents.js"
AGENTOS_MIGRATION_ROOT="$migration_root" AGENTOS_WORKSTATION_HOME=/home/admin bash -c 'source "$1"; post_install' _ "$repo_root/packages/agentos-shell/agentos-shell.install"
[[ -e "$migration_root/usr/share/wallpapers/AgentOS/wallpaper.svg" ]]
[[ -e "$migration_root/home/admin/.config/systemd/user/agentos-home.service" ]]
[[ -e "$migration_root/home/admin/.config/systemd/user/agentos-ui@.service" ]]
[[ -e "$migration_root/home/admin/.local/share/kwin/scripts/agentos-shell" ]]

# Package post-install hooks must converge an already-running user manager, not
# only create global enablement symlinks for a future login.
runtime_root="$tmp/run/user"
mkdir -p "$runtime_root/1000"
cat > "$fake_bin/id" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == -u ]] && { echo 1000; exit 0; }
exit 1
EOF
cat > "$fake_bin/runuser" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGENTOS_RUNUSER_LOG"
EOF
chmod 755 "$fake_bin/id" "$fake_bin/runuser"

runuser_log="$tmp/runuser.log"
PATH="$fake_bin:$PATH" AGENTOS_WORKSTATION_USER=admin AGENTOS_RUNTIME_ROOT="$runtime_root" \
  AGENTOS_RUNUSER_LOG="$runuser_log" bash -c 'source "$1"; _reload_active_user_manager' _ \
  "$repo_root/packages/agentos-runtime/agentos-runtime.install"
grep -Fq 'systemctl --user daemon-reload' "$runuser_log"
grep -Fq 'systemctl --user enable --now agentosd.service agentos-herdr-bridge.service' "$runuser_log"

: > "$runuser_log"
PATH="$fake_bin:$PATH" AGENTOS_WORKSTATION_USER=admin AGENTOS_RUNTIME_ROOT="$runtime_root" \
  AGENTOS_RUNUSER_LOG="$runuser_log" bash -c 'source "$1"; _reload_active_user_manager' _ \
  "$repo_root/packages/agentos-shell/agentos-shell.install"
grep -Fq 'systemctl --user daemon-reload' "$runuser_log"
grep -Fq 'systemctl --user enable --now agentos-home.service' "$runuser_log"

# The versioned runner keeps system and user queues separate, applies only an
# explicit scope, and records success so reruns are no-ops.
runner_root="$tmp/versioned-runner"
definitions="$runner_root/definitions"
system_state="$runner_root/system-state"
user_state="$runner_root/user-state"
runner_log="$runner_root/executed.log"
mkdir -p "$definitions/system" "$definitions/user"
cat > "$definitions/system/20260906-001-system-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'system\n' >> "$AGENTOS_MIGRATION_TEST_LOG"
EOF
cat > "$definitions/user/20260906-001-user-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'user\n' >> "$AGENTOS_MIGRATION_TEST_LOG"
EOF
chmod 644 "$definitions/system/20260906-001-system-check.sh" "$definitions/user/20260906-001-user-check.sh"

runner_env=(
	AGENTOS_MIGRATION_TEST_MODE=1
	AGENTOS_MIGRATIONS_DIR="$definitions"
  AGENTOS_SYSTEM_MIGRATION_STATE="$system_state"
  AGENTOS_USER_MIGRATION_STATE="$user_state"
  AGENTOS_MIGRATION_TEST_LOG="$runner_log"
)
run_agentos() {
  (cd "$repo_root/core" && env "${runner_env[@]}" go run ./cmd/agentos-ops "$@")
}
run_agentos migrate status --json > "$runner_root/status.json"
jq -e '.schema == "agentos.migrations/v1" and (.scopes | length == 2)' "$runner_root/status.json" >/dev/null
jq -e '.scopes[] | select(.scope == "system") | .migrations[0].status == "pending"' "$runner_root/status.json" >/dev/null
jq -e '.scopes[] | select(.scope == "user") | .migrations[0].status == "pending"' "$runner_root/status.json" >/dev/null

if run_agentos migrate apply --json >/dev/null 2>&1; then
  echo 'Migration apply accepted an implicit scope.' >&2
  exit 1
fi
run_agentos migrate apply --scope user --json > "$runner_root/applied.json"
jq -e '.scopes[0].scope == "user" and .scopes[0].migrations[0].status == "applied"' "$runner_root/applied.json" >/dev/null
run_agentos migrate apply --scope user --json >/dev/null
[[ "$(cat "$runner_log")" == 'user' ]]
[[ ! -e "$system_state/state.json" ]]
jq -e '.schema == 1 and (.applied | length == 1) and (.failed | length == 0)' "$user_state/state.json" >/dev/null

# Package migrations target only known legacy AgentOS state.
legacy_home="$runner_root/legacy-home"
mkdir -p "$legacy_home/.config/systemd/user" "$legacy_home/.local/share/kwin/scripts/agentos-shell" "$legacy_home/.config/owner"
touch "$legacy_home/.config/systemd/user/agentos-home.service"
touch "$legacy_home/.config/systemd/user/agentos-ui@.service"
touch "$legacy_home/.local/share/kwin/scripts/agentos-shell/contents.js"
touch "$legacy_home/.config/owner/custom.conf"
HOME="$legacy_home" bash "$repo_root/migrations/user/20260906-001-remove-legacy-shell-overrides.sh"
[[ ! -e "$legacy_home/.config/systemd/user/agentos-home.service" ]]
[[ ! -e "$legacy_home/.config/systemd/user/agentos-ui@.service" ]]
[[ ! -e "$legacy_home/.local/share/kwin/scripts/agentos-shell" ]]
[[ -e "$legacy_home/.config/owner/custom.conf" ]]

system_migration_log="$runner_root/system-migration.log"
cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGENTOS_MIGRATION_TEST_LOG"
EOF
chmod 755 "$fake_bin/systemctl"
AGENTOS_MIGRATION_ROOT="$migration_root" \
  bash "$repo_root/migrations/system/20260906-001-remove-legacy-wallpaper.sh"
[[ ! -e "$migration_root/usr/share/wallpapers/AgentOS/wallpaper.svg" ]]
PATH="$fake_bin:$PATH" AGENTOS_MIGRATION_TEST_LOG="$system_migration_log" \
  bash "$repo_root/migrations/system/20260906-002-clear-legacy-health-failure.sh"
grep -Fxq 'reset-failed workstation-health-check.service' "$system_migration_log"

recovery_bundle="$migration_root/.snapshots/boot/pre-pacman-20260907-100000"
recovery_state="$migration_root/var/lib/agentos/rollback.env"
mkdir -p "$recovery_bundle/loader/entries" "$(dirname "$recovery_state")"
touch "$recovery_bundle/loader/entries/arch.conf" "$recovery_bundle/MANIFEST.sha256" "$recovery_state"
chmod 700 "$migration_root/.snapshots/boot" "$recovery_bundle" "$recovery_bundle/loader" "$recovery_bundle/loader/entries"
chmod 600 "$recovery_bundle/loader/entries/arch.conf" "$recovery_bundle/MANIFEST.sha256" "$recovery_state"
AGENTOS_MIGRATION_ROOT="$migration_root" \
  bash "$repo_root/migrations/system/20260907-001-expose-recovery-metadata.sh"
permission_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
[[ "$(permission_mode "$recovery_bundle")" == 755 ]]
[[ "$(permission_mode "$recovery_bundle/loader/entries/arch.conf")" == 644 ]]
[[ "$(permission_mode "$recovery_state")" == 644 ]]

# Login notification is silent without pending user work and launches only the
# fixed visible user-scope migration after the notification action is selected.
notify_root="$runner_root/notify"
mkdir -p "$notify_root/bin"
cat > "$notify_root/bin/agentos" <<'EOF'
#!/usr/bin/env bash
cat "$AGENTOS_NOTIFY_REPORT"
EOF
cat > "$notify_root/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGENTOS_NOTIFY_LOG"
printf '%s\n' "${AGENTOS_NOTIFY_ACTION:-default}"
EOF
cat > "$notify_root/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGENTOS_LAUNCH_LOG"
EOF
chmod 755 "$notify_root/bin/"*
notify_report="$notify_root/report.json"
notify_log="$notify_root/notify.log"
launch_log="$notify_root/launch.log"
cat > "$notify_report" <<'EOF'
{"schema":"agentos.migrations/v1","scopes":[{"scope":"user","migrations":[]}]}
EOF
PATH="$notify_root/bin:$PATH" AGENTOS_NOTIFY_REPORT="$notify_report" \
  AGENTOS_NOTIFY_AGENTOS_BIN="$notify_root/bin/agentos" \
  AGENTOS_NOTIFY_LOG="$notify_log" AGENTOS_LAUNCH_LOG="$launch_log" \
  bash "$repo_root/agentos-migrate-notify.sh"
[[ ! -e "$notify_log" && ! -e "$launch_log" ]]
cat > "$notify_report" <<'EOF'
{"schema":"agentos.migrations/v1","scopes":[{"scope":"user","migrations":[{"id":"20260906-001-user-check","status":"pending"}]}]}
EOF
PATH="$notify_root/bin:$PATH" AGENTOS_NOTIFY_REPORT="$notify_report" \
  AGENTOS_NOTIFY_AGENTOS_BIN="$notify_root/bin/agentos" \
  AGENTOS_NOTIFY_LOG="$notify_log" AGENTOS_LAUNCH_LOG="$launch_log" \
  bash "$repo_root/agentos-migrate-notify.sh"
grep -Fq -- '--action=default=Review and apply' "$notify_log"
grep -Fq 'agentos migrate apply --scope user' "$launch_log"
cat > "$notify_report" <<'EOF'
{"schema":"agentos.migrations/v1","scopes":[{"scope":"user","migrations":[{"id":"20260906-001-user-check","status":"failed"}]}]}
EOF
: > "$notify_log"
: > "$launch_log"
PATH="$notify_root/bin:$PATH" AGENTOS_NOTIFY_REPORT="$notify_report" \
  AGENTOS_NOTIFY_AGENTOS_BIN="$notify_root/bin/agentos" \
  AGENTOS_NOTIFY_LOG="$notify_log" AGENTOS_LAUNCH_LOG="$launch_log" \
  AGENTOS_NOTIFY_ACTION=dismissed bash "$repo_root/agentos-migrate-notify.sh"
grep -Fq -- '--urgency=critical' "$notify_log"
[[ ! -s "$launch_log" ]]

echo 'AgentOS migration tests passed.'
