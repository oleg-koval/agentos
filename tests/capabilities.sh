#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mocks="$tmp/bin"
mkdir -p "$mocks"

cat > "$mocks/pacman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -Q && "${2:-}" == chromium ]]; then
  exit 0
fi
if [[ "${1:-}" == -Q ]]; then
  exit 1
fi
printf '%s\n' "pacman $*" >> "${CAPABILITY_TEST_LOG:?}"
exit 1
EOF

cat > "$mocks/ollama" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list)
    printf 'NAME ID SIZE MODIFIED\n'
    ;;
  pull)
    printf 'ollama pull %s\n' "${2:-}" >> "${CAPABILITY_TEST_LOG:?}"
    ;;
  *)
    exit 1
    ;;
esac
EOF

cat > "$mocks/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sudo %s\n' "$*" >> "${CAPABILITY_TEST_LOG:?}"
exit 0
EOF

cat > "$mocks/install-agent-tools" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'install-agent-tools %s\n' "$*" >> "${CAPABILITY_TEST_LOG:?}"
EOF

chmod +x "$mocks"/*

run_cli() {
  CAPABILITY_TEST_LOG="$tmp/operations.log" \
    AGENTOS_CAPABILITIES_FILE="$repo_root/registry/capabilities.json" \
    PATH="$mocks:$PATH" \
    bash "$repo_root/agentos-cli.sh" "$@"
}

: > "$tmp/operations.log"
plan_output="$(run_cli plan browser qwen-coder ci-repair)"
grep -Fqx 'browser: satisfied' <<<"$plan_output"
grep -Fqx 'qwen-coder: pending' <<<"$plan_output"
grep -Fqx 'ci-repair: provided' <<<"$plan_output"
[[ ! -s "$tmp/operations.log" ]] || {
  echo 'agentos plan invoked a mutating command.' >&2
  exit 1
}

: > "$tmp/operations.log"
apply_output="$(run_cli apply browser qwen-coder)"
grep -Fqx 'browser: skipped (satisfied)' <<<"$apply_output"
grep -Fqx 'qwen-coder: applied' <<<"$apply_output"
grep -Fqx 'ollama pull qwen2.5-coder:7b' "$tmp/operations.log"
! grep -Fq 'sudo' "$tmp/operations.log"

: > "$tmp/operations.log"
grep -Fqx 'github: applied' <(run_cli apply github)
grep -Fqx 'sudo pacman -S --needed github-cli' "$tmp/operations.log"

: > "$tmp/operations.log"
if run_cli apply browser unknown >"$tmp/unknown.out" 2>&1; then
  echo 'agentos apply accepted an unknown capability.' >&2
  exit 1
fi
grep -Fq 'Unknown capability: unknown' "$tmp/unknown.out"
[[ ! -s "$tmp/operations.log" ]] || {
  echo 'agentos apply mutated state before validating all names.' >&2
  exit 1
}

list_output="$(run_cli store list)"
grep -Fq 'Capabilities:' <<<"$list_output"
for capability in browser github supabase vercel docker postgres; do
  grep -Fq "$capability" <<<"$list_output"
done

# Agent registry IDs must be forwarded unchanged to the user-scoped installer.
: > "$tmp/operations.log"
AGENTOS_OPS_BIN='' run_cli store install hermes >/dev/null 2>&1 || true
grep -Fqx 'install-agent-tools --agent hermes' "$tmp/operations.log"

echo 'Capability plan/apply validation passed.'
