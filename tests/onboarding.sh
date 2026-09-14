#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/agentos-onboarding.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

grep -Fq 'install -Dm755 "$src/agentos-onboarding.sh" "$pkgdir/usr/bin/agentos-onboarding"' \
  "$repo_root/packages/agentos-runtime/PKGBUILD"

fake_bin="$tmp/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -n ]] && shift
[[ "${1:-}" == true ]] && exit 0
exec "$@"
EOF

cat > "$fake_bin/agentos-repository" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${AGENTOS_TEST_REPOSITORY_READY:-1}" == 1 ]]; then
  printf '%s\n' '{"configured":true,"state_configured":true,"pacman_configured":true,"trusted_key":true,"repository_reachable":true,"include":"/etc/pacman.d/agentos.conf","fingerprint":"3060184CFC884D14CB1D54F9CA25144B4E4DBA8E"}'
else
  printf '%s\n' '{"configured":false,"state_configured":true,"pacman_configured":true,"trusted_key":false,"repository_reachable":false}'
fi
EOF

cat > "$fake_bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -Q ]] || exit 2
printf '%s\n' 'agentos-runtime 0.4.13-3' 'agentos-shell 0.4.3-1'
EOF

cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --user ]]; then
  service="${4:-}"
  if [[ "$service" == agentos-home.service && "${AGENTOS_TEST_HOME_ACTIVE:-1}" == 1 ]]; then
    exit 0
  fi
  [[ "$service" == app-org.kde.krdpserver.service ]] && exit 0
fi
if [[ "${1:-}" == is-active && ( "${3:-}" == sshd || "${3:-}" == tailscaled ) ]]; then exit 0; fi
exit 1
EOF

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ok\n'
EOF

cat > "$fake_bin/tailscale" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == ip && "${2:-}" == -4 ]] && printf '100.64.0.1\n' && exit 0
exit 2
EOF

cat > "$fake_bin/agentos-config" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"schema":"agentos.config/v1","changes":[]}'
EOF

cat > "$fake_bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "${AGENTOS_TEST_SSH_LOG:?}"
cat >/dev/null
exit "${AGENTOS_TEST_SSH_STATUS:-0}"
EOF

chmod 755 "$fake_bin"/*

help_output="$(bash "$repo_root/agentos-cli.sh" help)"
grep -Fq 'agentos plan [capability...]' <<<"$help_output"
grep -Fq 'agentos apply [capability...]' <<<"$help_output"

run_local() {
  PATH="$fake_bin:$PATH" WAYLAND_DISPLAY=wayland-1 "$@"
}

output="$(run_local bash "$script" --local)"
grep -Fq '[OK]   SSH service' <<<"$output"
grep -Fq '[OK]   Signed repository' <<<"$output"
grep -Fq '[OK]   AgentOS packages' <<<"$output"
grep -Fq '[OK]   AgentOS local API' <<<"$output"
grep -Fq '[OK]   AgentOS Home' <<<"$output"
grep -Fq '[SKIP] Tailscale' <<<"$output"
grep -Fq '[SKIP] KRDP' <<<"$output"

config_file="$tmp/first-run.yaml"
printf 'version: 1\n' > "$config_file"
config_output="$(run_local env AGENTOS_ONBOARDING_CONFIG="$config_file" bash "$script" --local)"
grep -Fq '[OK]   First-run config' <<<"$config_output"

headless_output="$(PATH="$fake_bin:$PATH" AGENTOS_TEST_HOME_ACTIVE=0 env -u WAYLAND_DISPLAY bash "$script" --local)"
grep -Fq '[SKIP] AgentOS Home' <<<"$headless_output"
grep -Fq 'no Wayland session' <<<"$headless_output"

if output="$(run_local env AGENTOS_TEST_REPOSITORY_READY=0 bash "$script" --local 2>&1)"; then
  echo 'unready repository unexpectedly passed' >&2
  exit 1
fi
grep -Fq '[FAIL]  Signed repository' <<<"$output"

output="$(run_local bash "$script" --local --tailscale --krdp)"
grep -Fq '[OK]   Tailscale' <<<"$output"
grep -Fq '[OK]   KRDP' <<<"$output"

ssh_log="$tmp/ssh.log"
PATH="$fake_bin:$PATH" AGENTOS_TEST_SSH_LOG="$ssh_log" bash "$script" --tailscale example@vps.example
grep -Fq -- '-tt' "$ssh_log"
grep -Fq -- '-o ConnectTimeout=10' "$ssh_log"
grep -Fq -- 'example@vps.example' "$ssh_log"
grep -Fq -- 'sudo -v && agentos-onboarding --local --remote-session --tailscale' "$ssh_log"

if PATH="$fake_bin:$PATH" AGENTOS_TEST_SSH_LOG="$ssh_log" AGENTOS_TEST_SSH_STATUS=255 \
  bash "$script" example@vps.example >/dev/null 2>&1; then
  echo 'unreachable SSH target unexpectedly passed' >&2
  exit 1
fi

if grep -Eq 'StrictHostKeyChecking=no|UserKnownHostsFile=/dev/null|sshpass|pacman -S|systemctl (start|restart|enable|disable)' "$script"; then
  echo 'onboarding validator contains an unsafe mutating or access-bypassing operation' >&2
  exit 1
fi

echo 'AgentOS onboarding tests passed.'
