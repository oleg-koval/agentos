#!/usr/bin/env bash
set -euo pipefail

entrypoint_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${AGENTOS_OPS_BIN:-}" ]]; then
  exec "$AGENTOS_OPS_BIN" --entrypoint transaction "$@"
elif [[ -x /usr/bin/agentos-ops ]]; then
  exec /usr/bin/agentos-ops --entrypoint transaction "$@"
elif [[ -f "$entrypoint_dir/core/go.mod" ]] && command -v go >/dev/null 2>&1; then
  cd "$entrypoint_dir/core"
  exec env AGENTOS_REPO_ROOT="$entrypoint_dir" go run ./cmd/agentos-ops --entrypoint transaction "$@"
fi
echo 'AgentOS operations binary is not installed; build core/cmd/agentos-ops first.' >&2
exit 127
