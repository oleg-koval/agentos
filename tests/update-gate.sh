#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/core"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "tests/update-gate.sh must run as root (agentos-weekly-update requires root)" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fake_bin="$tmp/bin"
mkdir -p "$fake_bin"
for cmd in systemctl workstation-doctor agentos-boot-health; do
  cat > "$fake_bin/$cmd" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$fake_bin/$cmd"
done

cat > "$fake_bin/btrfs-pre-pacman-snapshot" <<'EOF'
#!/usr/bin/env bash
echo 'Created pre-pacman snapshot: /.snapshots/pre-pacman-test'
EOF
chmod +x "$fake_bin/btrfs-pre-pacman-snapshot"

rollback_log="$tmp/rollback.log"
cat > "$fake_bin/rollback-workstation" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$rollback_log"
EOF
chmod +x "$fake_bin/rollback-workstation"

pacman_log="$tmp/pacman.log"
: > "$pacman_log"
cat > "$fake_bin/pacman" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$pacman_log"
exit 0
EOF
chmod +x "$fake_bin/pacman"

checkupdates_output="$tmp/checkupdates.out"
cat > "$fake_bin/checkupdates" <<EOF
#!/usr/bin/env bash
if [[ -s "$checkupdates_output" ]]; then cat "$checkupdates_output"; exit 0; fi
exit 2
EOF
chmod +x "$fake_bin/checkupdates"

cat > "$fake_bin/gpg" <<'EOF'
#!/usr/bin/env bash
expiry=$(( $(date +%s) + 40 * 86400 ))
cat <<INNEREOF
sub:::::::::::::
sub:u:255:22:AAAA:0:${expiry}::::::::
INNEREOF
EOF
chmod +x "$fake_bin/gpg"

state="$tmp/state"
mkdir -p "$state"
migration_definitions="$tmp/migrations"
migration_state="$tmp/migration-state"
mkdir -p "$migration_definitions/system" "$migration_definitions/user"
channel_file="$tmp/channel"
version_file="$tmp/version"
update_result="$tmp/update-result.json"
update_check="$tmp/update-check.json"
boot_id_file="$tmp/boot-id"
echo '0.1.0' > "$version_file"
echo 'boot-a' > "$boot_id_file"
pacman_conf="$tmp/pacman.conf"
pacman_inc="$tmp/agentos.conf"
: > "$pacman_conf"

run_update() {
  local mode="${1:---manual}"
  PATH="$fake_bin:$PATH" \
  AGENTOS_STATE_DIR="$state" \
  AGENTOS_CHANNEL_FILE="$channel_file" \
  AGENTOS_VERSION_FILE="$version_file" \
  AGENTOS_UPDATE_RESULT_STATE="$update_result" \
  AGENTOS_BOOT_ID_FILE="$boot_id_file" \
  AGENTOS_UPDATE_MANIFEST_DIR="$manifest_dir" \
  AGENTOS_SIGNING_KEY_FILE="$signing_key" \
  AGENTOS_VERIFY_REPO_SCRIPT="$verify_repo" \
  AGENTOS_REPOSITORY_STATE="$state/repository.json" \
  PACMAN_CONF="$pacman_conf" \
  AGENTOS_PACMAN_INCLUDE="$pacman_inc" \
  AGENTOS_REPOSITORY_TEST_MODE=1 \
  AGENTOS_MIGRATION_TEST_MODE=1 \
  AGENTOS_MIGRATIONS_DIR="$migration_definitions" \
  AGENTOS_SYSTEM_MIGRATION_STATE="$migration_state" \
  go run ./cmd/agentos-ops --entrypoint update "$mode"
}

run_check() {
  PATH="$fake_bin:$PATH" \
  AGENTOS_STATE_DIR="$state" \
  AGENTOS_CHANNEL_FILE="$channel_file" \
  AGENTOS_VERSION_FILE="$version_file" \
  AGENTOS_UPDATE_CHECK_STATE="$update_check" \
  AGENTOS_UPDATE_MANIFEST_DIR="$manifest_dir" \
  AGENTOS_SIGNING_KEY_FILE="$signing_key" \
  AGENTOS_VERIFY_REPO_SCRIPT="$verify_repo" \
  AGENTOS_REPOSITORY_STATE="$state/repository.json" \
  PACMAN_CONF="$pacman_conf" \
  AGENTOS_PACMAN_INCLUDE="$pacman_inc" \
  AGENTOS_REPOSITORY_TEST_MODE=1 \
  go run ./cmd/agentos-ops --entrypoint agentos update --check
}

run_channel() {
  PATH="$fake_bin:$PATH" \
  AGENTOS_STATE_DIR="$state" \
  AGENTOS_CHANNEL_FILE="$channel_file" \
  AGENTOS_REPOSITORY_STATE="$state/repository.json" \
  PACMAN_CONF="$pacman_conf" \
  AGENTOS_PACMAN_INCLUDE="$pacman_inc" \
  AGENTOS_REPOSITORY_TEST_MODE=1 \
  go run ./cmd/agentos-ops --entrypoint agentos channel "$@"
}

# Task 9 made "agentos-repository verify" also verify repository signatures, which
# needs the installed signing key and the shared verifier script. This test is
# about the update gate, not about signature verification, so it points both at
# fixtures; tests/repository-verify-signatures.sh covers the real verifier.
signing_key="$tmp/agentos-signing.asc"
: > "$signing_key"
verify_repo="$tmp/verify-repo.sh"
cat > "$verify_repo" <<'VERIFYEOF'
#!/usr/bin/env bash
[[ "${AGENTOS_VERIFY_FAIL:-0}" != 1 ]]
VERIFYEOF
chmod +x "$verify_repo"
manifest_dir="$tmp/manifest"
mkdir -p "$manifest_dir"
cat > "$manifest_dir/release-manifest.json" <<'EOF'
{"schema":"agentos.release/v2","channel":"stable","version":"0.2.0","repository_url":"https://example.invalid/agentos","packages":[{"name":"agentos-base-0.1.0-2-x86_64.pkg.tar.zst"},{"name":"agentos-keyring-1-1-any.pkg.tar.zst"},{"name":"agentos-runtime-0.4.13-39-x86_64.pkg.tar.zst"},{"name":"agentos-shell-0.4.3-16-x86_64.pkg.tar.zst"}]}
EOF
: > "$manifest_dir/release-manifest.json.asc"

# verify fetches the repository's signed artifacts before handing them to the
# verifier, and this fixture repository is not reachable. The stub curl is on a
# path only "agentos-repository verify" sees, so the update path still runs
# against the unmodified environment.
verify_bin="$tmp/verify-bin"
mkdir -p "$verify_bin"
cat > "$verify_bin/curl" <<'CURLEOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] && : > "$out"
exit 0
CURLEOF
chmod +x "$verify_bin/curl"

run_repository() {
  PATH="$verify_bin:$fake_bin:$PATH" \
  AGENTOS_STATE_DIR="$state" \
  AGENTOS_CHANNEL_FILE="$channel_file" \
  AGENTOS_REPOSITORY_STATE="$state/repository.json" \
  PACMAN_CONF="$pacman_conf" \
  AGENTOS_PACMAN_INCLUDE="$pacman_inc" \
  AGENTOS_REPOSITORY_TEST_MODE=1 \
  AGENTOS_SIGNING_KEY_FILE="$signing_key" \
  AGENTOS_VERIFY_REPO_SCRIPT="$verify_repo" \
  go run ./cmd/agentos-ops --entrypoint repository "$@"
}

echo stable > "$channel_file"
if run_update >"$tmp/out.txt" 2>&1; then
  echo "expected update to fail when channel=stable and the repository is unconfigured" >&2
  cat "$tmp/out.txt" >&2
  exit 1
fi
grep -Fq 'requires a configured AgentOS repository' "$tmp/out.txt"

echo none > "$channel_file"
if ! run_update >"$tmp/out2.txt" 2>&1; then
  echo "expected update to succeed when channel=none and the repository is unconfigured" >&2
  cat "$tmp/out2.txt" >&2
  exit 1
fi

echo beta > "$channel_file"
: > "$pacman_log"
if ! run_update --scheduled >"$tmp/out-beta-scheduled.txt" 2>&1; then
  echo 'expected scheduled beta update to be skipped cleanly' >&2
  exit 1
fi
grep -Fq 'Automatic weekly updates only apply on stable channel' "$tmp/out-beta-scheduled.txt"
[[ ! -s "$pacman_log" ]]

if ! run_channel none >"$tmp/out3.txt" 2>&1; then
  echo "expected agentos channel none to succeed" >&2
  cat "$tmp/out3.txt" >&2
  exit 1
fi
[[ "$(cat "$channel_file")" == "none" ]] || { echo "channel file was not set to none" >&2; exit 1; }

if run_channel bogus >"$tmp/out4.txt" 2>&1; then
  echo "expected agentos channel bogus to be rejected" >&2
  cat "$tmp/out4.txt" >&2
  exit 1
fi
grep -Fq 'channel must be stable, beta, edge, or none' "$tmp/out4.txt"

echo bogus > "$channel_file"
if run_update >"$tmp/out5.txt" 2>&1; then
  echo "expected update to fail when the channel file contains an invalid channel" >&2
  cat "$tmp/out5.txt" >&2
  exit 1
fi
grep -Fq 'invalid AgentOS channel: bogus' "$tmp/out5.txt"

cat > "$pacman_conf" <<CONFEOF
Include = $pacman_inc
CONFEOF

cat > "$pacman_inc" <<INCEOF
[agentos]
SigLevel = Required
Server = https://example.invalid/agentos/stable
INCEOF

cat > "$state/repository.json" <<REPOEOF
{"schema":"agentos.repository/v1","configured":true,"url":"https://example.invalid/agentos/stable","fingerprint":"3060184CFC884D14CB1D54F9CA25144B4E4DBA8E","include":"$pacman_inc"}
REPOEOF

if ! run_repository verify >"$tmp/out6.txt" 2>&1; then
  echo "expected agentos-repository verify to succeed with a configured repository" >&2
  cat "$tmp/out6.txt" >&2
  exit 1
fi
grep -Fq '[OK]   repository state: configured' "$tmp/out6.txt"
grep -Fq '[OK]   pacman configuration:' "$tmp/out6.txt"
grep -Fq '[OK]   signing subkey expiry:' "$tmp/out6.txt"
grep -Fq '[OK]   signature verification:' "$tmp/out6.txt"

echo stable > "$channel_file"
cat > "$pacman_inc" <<'INCEOF'
[agentos]
SigLevel = Required
Server = https://mirror.invalid/agentos/stable
INCEOF
if run_check >"$tmp/out-mismatched-repository.txt" 2>&1; then
  echo 'expected update check to reject mismatched pacman trust state' >&2
  exit 1
fi
grep -Fq 'pacman repository does not match configured trust state' "$tmp/out-mismatched-repository.txt"
cat > "$pacman_inc" <<'INCEOF'
[agentos]
SigLevel = Required
Server = https://example.invalid/agentos/stable
INCEOF

if ! run_check >"$tmp/out-check.txt" 2>&1; then
  echo 'expected signed update check to succeed' >&2
  cat "$tmp/out-check.txt" >&2
  exit 1
fi
jq -e '.schema == "agentos.update/v1" and .status == "available" and .current_version == "0.1.0" and .target_version == "0.2.0" and .arch_pending == 0' "$update_check" >/dev/null

: > "$pacman_log"
if AGENTOS_VERIFY_FAIL=1 run_update >"$tmp/out-signature.txt" 2>&1; then
  echo 'expected update to fail before mutation when release metadata verification fails' >&2
  exit 1
fi
grep -Fq 'release metadata signature verification failed' "$tmp/out-signature.txt"
if grep -Eq -- '^-S(y|yu)( |$)' "$pacman_log"; then
  echo 'signature failure must stop before package mutation' >&2
  exit 1
fi
jq -e '.status == "apply-failed" and .last_failure != ""' "$update_result" >/dev/null

if AGENTOS_VERIFY_FAIL=1 run_check >"$tmp/out-check-signature.txt" 2>&1; then
  echo 'expected signed update check failure to be durable' >&2
  exit 1
fi
jq -e '.status == "check-failed" and .last_failure != ""' "$update_check" >/dev/null

: > "$pacman_log"
echo 'linux 6.10 6.11' > "$checkupdates_output"
if ! run_update >"$tmp/out7.txt" 2>&1; then
  echo "expected update to succeed when channel=stable and the repository is configured" >&2
  cat "$tmp/out7.txt" >&2
  exit 1
fi
grep -Fq -- '-S --needed --noconfirm agentos-keyring' "$pacman_log"
jq -e '.schema == "agentos.update/v1" and .status == "reboot-required" and .target_version == "0.2.0" and .snapshot_id == "pre-pacman-test" and .migration_status == "succeeded" and .last_success_at != "" and .boot_id == "boot-a"' "$update_result" >/dev/null
[[ "$(cat "$version_file")" == '0.2.0' ]]
last_update_before="$(cat "$state/last-update")"
: > "$checkupdates_output"

cat > "$migration_definitions/system/20260906-001-fail-update.sh" <<'EOF'
#!/usr/bin/env bash
exit 23
EOF
cat > "$migration_definitions/system/20260906-002-must-not-run.sh" <<EOF
#!/usr/bin/env bash
touch "$tmp/later-migration-ran"
EOF
chmod 644 "$migration_definitions/system/"*.sh
: > "$rollback_log"
if run_update >"$tmp/out8.txt" 2>&1; then
  echo 'expected update to fail when a system migration fails' >&2
  cat "$tmp/out8.txt" >&2
  exit 1
fi
grep -Fq 'System migration failed' "$tmp/out8.txt"
grep -Fxq 'stage pre-pacman-test' "$rollback_log"
[[ ! -e "$tmp/later-migration-ran" ]]
[[ "$(cat "$state/last-update")" == "$last_update_before" ]]
jq -e '.status == "apply-failed" and .migration_status == "failed" and .snapshot_id == "pre-pacman-test" and .last_success_at != ""' "$update_result" >/dev/null

echo "update-gate.sh test passed."
