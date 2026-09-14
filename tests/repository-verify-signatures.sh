#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"; mkdir "$bin"
cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
for ((i=1; i<=$#; i++)); do
  [[ "${!i}" == --output ]] && { j=$((i+1)); echo fetched > "${!j}"; exit 0; }
done
EOF
chmod +x "$bin/curl"
cat > "$bin/gpg" <<'EOF'
#!/usr/bin/env bash
echo "sub:u:255:22:AAAA:0:$(( $(date -u +%s) + 200*86400 ))::::::::"
EOF
chmod +x "$bin/gpg"
key="$tmp/key.asc"; echo public > "$key"
good="$tmp/good"; printf '#!/usr/bin/env bash\nexit 0\n' > "$good"; chmod +x "$good"
bad="$tmp/bad"; printf '#!/usr/bin/env bash\nexit 1\n' > "$bad"; chmod +x "$bad"
state="$tmp/state"; mkdir "$state"
printf '%s\n' '{"schema":"agentos.repository/v1","configured":true,"url":"https://example.invalid/stable","fingerprint":"ABC"}' > "$state/repository.json"
include="$tmp/include"; printf '[agentos]\nSigLevel = Required\nServer = https://example.invalid/stable\n' > "$include"
pacman_conf="$tmp/pacman.conf"; printf 'Include = %s\n' "$include" > "$pacman_conf"
run() { (cd "$root/core" && PATH="$bin:$PATH" AGENTOS_STATE_DIR="$state" AGENTOS_SIGNING_KEY_FILE="$key" AGENTOS_VERIFY_REPO_SCRIPT="$1" PACMAN_CONF="$pacman_conf" AGENTOS_PACMAN_INCLUDE="$include" AGENTOS_REPOSITORY_TEST_MODE=1 GOCACHE=/tmp/agentos-go-cache go run ./cmd/agentos-ops --entrypoint repository verify); }
run "$good" > "$tmp/good-out" 2>&1 || { cat "$tmp/good-out" >&2; exit 1; }
grep -Fq '[OK]   signature verification' "$tmp/good-out"
if run "$bad" > "$tmp/out" 2>&1; then exit 1; fi
grep -Fq '[FAIL] signature verification' "$tmp/out"
echo 'repository-verify-signatures.sh test passed.'
