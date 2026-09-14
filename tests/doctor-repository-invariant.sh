#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/core"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_doctor() {
  local channel_val="$1" state_dir="$2" pacman_conf="$3" pacman_inc="$4"
  local channel_file="$tmp/channel-$RANDOM"
  echo "$channel_val" > "$channel_file"
  AGENTOS_CHANNEL_FILE="$channel_file" \
  AGENTOS_STATE_DIR="$state_dir" \
  AGENTOS_PACMAN_CONF="$pacman_conf" \
  AGENTOS_PACMAN_INCLUDE="$pacman_inc" \
  go run ./cmd/agentos-ops --entrypoint doctor --check || true
}

assert_invariant_line() {
  local output="$1" tag="$2" message="$3"
  local line
  line="$(echo "$output" | grep -F 'Repository channel')"
  echo "$line" | grep -Fq "$tag" || { echo "expected tag $tag in line: $line" >&2; exit 1; }
  echo "$line" | grep -Fq "$message" || { echo "expected message '$message' in line: $line" >&2; exit 1; }
}

# Case 1: not configured -- channel set but no repository state at all.
not_configured_state="$tmp/not-configured"
mkdir -p "$not_configured_state"
output="$(run_doctor edge "$not_configured_state" "$tmp/pacman-nc.conf" "$tmp/agentos-nc.conf")"
assert_invariant_line "$output" "[FAIL]" "channel=edge but AgentOS repository is not configured"

# Case 2a: channel=none with nothing configured in pacman -- upstream Arch only.
output="$(run_doctor none "$tmp/none-state" "$tmp/pacman-none.conf" "$tmp/agentos-none.conf")"
assert_invariant_line "$output" "[OK]" "channel=none (upstream Arch only)"

# Case 2b: channel=none while the repository is still configured in pacman. Reporting
# OK here would call a machine healthy while pacman keeps pulling AgentOS packages,
# which is the opposite of what channel=none asks for. The channel file is writable
# by paths that never touch pacman (agentos channel, declarative config apply), so
# this state is reachable and doctor has to name the command that fixes it.
none_live_inc="$tmp/agentos-none-live.conf"
cat > "$none_live_inc" <<'EOF'
# Managed by agentos-repository. Do not weaken signature verification.
[agentos]
SigLevel = Required
Server = https://x.invalid/a/stable
EOF
none_live_conf="$tmp/pacman-none-live.conf"
cat > "$none_live_conf" <<EOF
Include = $none_live_inc
EOF
output="$(run_doctor none "$tmp/none-live-state" "$none_live_conf" "$none_live_inc")"
assert_invariant_line "$output" "[FAIL]" "channel=none but the AgentOS repository is still configured in pacman"
assert_invariant_line "$output" "[FAIL]" "agentos-repository set-channel none"

# Case 3: invalid channel value.
output="$(run_doctor bogus "$tmp/bogus-state" "$tmp/pacman-bogus.conf" "$tmp/agentos-bogus.conf")"
assert_invariant_line "$output" "[FAIL]" "invalid channel value: bogus"

# Case 4: URL suffix drift -- state.URL does not end in the active channel.
suffix_state_dir="$tmp/suffix-state"
mkdir -p "$suffix_state_dir"
cat > "$suffix_state_dir/repository.json" <<'EOF'
{"schema":"agentos.repository/v1","configured":true,"url":"https://x.invalid/a/stable","fingerprint":"3060184CFC884D14CB1D54F9CA25144B4E4DBA8E","include":""}
EOF
output="$(run_doctor beta "$suffix_state_dir" "$tmp/pacman-suffix.conf" "$tmp/agentos-suffix.conf")"
assert_invariant_line "$output" "[FAIL]" "channel=beta but repository URL is https://x.invalid/a/stable"

# Case 5: pacman/state drift -- state.URL matches the channel but the pacman include
# file (the file pacman actually reads) points somewhere else. This is the gap the
# review flagged: repositorySetChannel writes the include, then the state, then the
# channel file, in that order, so a failure between those writes can leave pacman
# pulling from a different channel than state.URL and the channel file both claim.
drift_state_dir="$tmp/drift-state"
mkdir -p "$drift_state_dir"
cat > "$drift_state_dir/repository.json" <<'EOF'
{"schema":"agentos.repository/v1","configured":true,"url":"https://x.invalid/a/stable","fingerprint":"3060184CFC884D14CB1D54F9CA25144B4E4DBA8E","include":""}
EOF
drift_pacman_inc="$tmp/agentos-drift.conf"
cat > "$drift_pacman_inc" <<'EOF'
# Managed by agentos-repository. Do not weaken signature verification.
[agentos]
SigLevel = Required
Server = https://x.invalid/a/beta
EOF
drift_pacman_conf="$tmp/pacman-drift.conf"
cat > "$drift_pacman_conf" <<EOF
Include = $drift_pacman_inc
EOF
output="$(run_doctor stable "$drift_state_dir" "$drift_pacman_conf" "$drift_pacman_inc")"
assert_invariant_line "$output" "[FAIL]" "channel=stable but pacman is configured for https://x.invalid/a/beta while recorded state says https://x.invalid/a/stable"

# Case 6: passing case -- state, pacman include, and pacman.conf all agree with the
# active channel. Fixture must have SigLevel = Required and a matching Include= line
# in pacman.conf, or repositoryConfigPresent returns false and this reports the
# "pacman is not configured" failure instead of OK.
pass_state_dir="$tmp/pass-state"
mkdir -p "$pass_state_dir"
cat > "$pass_state_dir/repository.json" <<'EOF'
{"schema":"agentos.repository/v1","configured":true,"url":"https://x.invalid/a/stable","fingerprint":"3060184CFC884D14CB1D54F9CA25144B4E4DBA8E","include":""}
EOF
pass_pacman_inc="$tmp/agentos-pass.conf"
cat > "$pass_pacman_inc" <<'EOF'
# Managed by agentos-repository. Do not weaken signature verification.
[agentos]
SigLevel = Required
Server = https://x.invalid/a/stable
EOF
pass_pacman_conf="$tmp/pacman-pass.conf"
cat > "$pass_pacman_conf" <<EOF
Include = $pass_pacman_inc
EOF
output="$(run_doctor stable "$pass_state_dir" "$pass_pacman_conf" "$pass_pacman_inc")"
assert_invariant_line "$output" "[OK]" "channel=stable matches the configured repository"

echo "doctor-repository-invariant.sh test passed."
