#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_helper="$tmp/fake-agentos-config"
cat > "$fake_helper" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *mark-applied* ]]; then
  exit 0
fi
cat <<'JSON'
{"schema":"agentos.config/v1","version":1,"mode":"plan","config":"/dev/null","config_hash":"deadbeef","state":"pending","migration":"none","changes":[{"path":"channel","type":"enum","desired":"none","actual":"stable","state":"pending","action":"channel"}]}
JSON
EOF
chmod +x "$fake_helper"

echo '{"capabilities":[]}' > "$tmp/registry.json"
channel_file="$tmp/channel"
echo stable > "$channel_file"
state_dir="$tmp/state"
mkdir -p "$state_dir"

AGENTOS_CONFIG_HELPER="$fake_helper" \
AGENTOS_CAPABILITIES_FILE="$tmp/registry.json" \
AGENTOS_CHANNEL_FILE="$channel_file" \
bash -c "cd '$repo_root/core' && go run ./cmd/agentos-ops --entrypoint agentos config --config /dev/null --state '$state_dir/state.json' apply" >"$tmp/apply.out"

grep -Fq '"state": "applied"' "$tmp/apply.out"
[[ "$(cat "$channel_file")" == "none" ]] || { echo "declarative config apply did not write channel=none" >&2; cat "$tmp/apply.out" >&2; exit 1; }

echo "config-channel-none.sh test passed."
