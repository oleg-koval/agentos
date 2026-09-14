#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ops="$tmp/agentos-ops"
(cd "$repo_root/core" && go build -o "$ops" ./cmd/agentos-ops)
state="$tmp/generations"
mocks="$tmp/mocks"
mkdir -p "$state/test-generation" "$mocks"
printf 'test-generation\n' > "$state/current"
printf 'pre-pacman-20260822-120000\n' > "$state/test-generation/snapshot.name"
printf '{}\n' > "$state/test-generation/before.json"

cat > "$mocks/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *is-enabled*app-org.kde.krdpserver.service*) exit 0 ;;
  *is-enabled*agentos-home.service*) exit 0 ;;
  *is-active*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$mocks/ss" <<'EOF'
#!/usr/bin/env bash
echo 'LISTEN 0 50 0.0.0.0:22 0.0.0.0:*'
echo 'LISTEN 0 50 0.0.0.0:3389 0.0.0.0:*'
EOF
cat > "$mocks/tailscale" <<'EOF'
#!/usr/bin/env bash
echo '100.64.0.1'
EOF
cat > "$mocks/hostname" <<'EOF'
#!/usr/bin/env bash
echo 'agentos-test'
EOF
cat > "$mocks/git" <<'EOF'
#!/usr/bin/env bash
echo 'deadbee'
EOF
cat > "$mocks/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$@"
EOF
cat > "$mocks/rollback-workstation" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == status ]]; then
  echo 'No rollback is staged.'
  exit 0
fi
if [[ "${1:-}" == stage ]]; then
  printf '%s\n' "$2" > "$ROLLBACK_LOG"
  exit 0
fi
exit 2
EOF
chmod +x "$mocks"/*

ROLLBACK_LOG="$tmp/rollback.log" \
AGENTOS_OPS_BIN="$ops" \
AGENTOS_TRANSACTION_ROOT="$state" \
AGENTOS_CHECKOUT="$tmp" \
PATH="$mocks:/usr/bin:/bin" \
  bash "$repo_root/agentos-transaction.sh" fail test-generation

[[ -f "$state/test-generation/failure.json" ]] || { echo 'missing failure metadata' >&2; exit 1; }
[[ "$(jq -r .status "$state/test-generation/failure.json")" == FAILED ]] || { echo 'generation not marked FAILED' >&2; exit 1; }
[[ "$(jq -r .host "$state/test-generation/failure.json")" == agentos-test ]] || { echo 'hostname not captured' >&2; exit 1; }
[[ "$(cat "$tmp/rollback.log")" == pre-pacman-20260822-120000 ]] || { echo 'matching snapshot was not staged' >&2; exit 1; }
[[ -f "$state/test-generation/rollback-staged" ]] || { echo 'rollback marker missing' >&2; exit 1; }

echo 'Transaction failure-path validation passed.'
