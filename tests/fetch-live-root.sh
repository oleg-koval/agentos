#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$repo_root/release/fetch-live-root.sh"
if command -v shellcheck >/dev/null 2>&1; then shellcheck -S error "$repo_root/release/fetch-live-root.sh"; fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

site="$tmp/site"
mkdir -p "$site"
printf '#!/usr/bin/env bash\necho live-stable-installer\n' > "$site/agentos-vps-install.sh"
(cd "$site" && sha256sum agentos-vps-install.sh > agentos-vps-install.sh.sha256)
echo "live-public-key" > "$site/agentos-repo-public.asc"
echo "LIVEFINGERPRINT" > "$site/fingerprint.txt"

port=18465
(cd "$site" && exec python3 -m http.server "$port" >/tmp/fetch-live-root-server.log 2>&1) &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
ready=''
for _ in $(seq 1 40); do
  curl -sSf "http://127.0.0.1:$port/agentos-vps-install.sh" >/dev/null 2>&1 && { ready=yes; break; }
  sleep 0.2
done
[[ -n "$ready" ]] || { echo "mock site server never came up on $port" >&2; cat /tmp/fetch-live-root-server.log >&2; exit 1; }

# Case 1: a published root is restored whole, executable, and checksum-verified.
dest="$tmp/dest"
bash "$repo_root/release/fetch-live-root.sh" "http://127.0.0.1:$port" "$dest"
for f in agentos-vps-install.sh agentos-vps-install.sh.sha256 agentos-repo-public.asc fingerprint.txt; do
  [[ -f "$dest/$f" ]] || { echo "live root file not restored: $f" >&2; exit 1; }
done
grep -Fq 'live-stable-installer' "$dest/agentos-vps-install.sh" \
  || { echo "restored installer is not the live one" >&2; exit 1; }
[[ -x "$dest/agentos-vps-install.sh" ]] \
  || { echo "restored installer is not executable" >&2; exit 1; }
(cd "$dest" && sha256sum -c agentos-vps-install.sh.sha256 >/dev/null) \
  || { echo "restored installer does not match its restored checksum" >&2; exit 1; }

# Case 2: a site that has never published a root is not an error, and leaves
# nothing behind for the caller to mistake for a live installer.
empty_site="$tmp/empty-site"
mkdir -p "$empty_site"
port2=18466
(cd "$empty_site" && exec python3 -m http.server "$port2" >/tmp/fetch-live-root-empty.log 2>&1) &
empty_pid=$!
trap 'kill "$server_pid" "$empty_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
ready=''
for _ in $(seq 1 40); do
  curl -sS "http://127.0.0.1:$port2/" >/dev/null 2>&1 && { ready=yes; break; }
  sleep 0.2
done
[[ -n "$ready" ]] || { echo "mock empty-site server never came up on $port2" >&2; exit 1; }
empty_dest="$tmp/empty-dest"
bash "$repo_root/release/fetch-live-root.sh" "http://127.0.0.1:$port2" "$empty_dest" 2>/dev/null
[[ ! -f "$empty_dest/agentos-vps-install.sh" ]] \
  || { echo "never-published root left an installer behind" >&2; exit 1; }

# Case 3: an installer that fails its own published checksum is refused, so a
# corrupted root is never republished as if it were good.
bad_site="$tmp/bad-site"
mkdir -p "$bad_site"
printf '#!/usr/bin/env bash\necho tampered\n' > "$bad_site/agentos-vps-install.sh"
echo "0000000000000000000000000000000000000000000000000000000000000000  agentos-vps-install.sh" \
  > "$bad_site/agentos-vps-install.sh.sha256"
port3=18467
(cd "$bad_site" && exec python3 -m http.server "$port3" >/tmp/fetch-live-root-bad.log 2>&1) &
bad_pid=$!
trap 'kill "$server_pid" "$empty_pid" "$bad_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
ready=''
for _ in $(seq 1 40); do
  curl -sSf "http://127.0.0.1:$port3/agentos-vps-install.sh" >/dev/null 2>&1 && { ready=yes; break; }
  sleep 0.2
done
[[ -n "$ready" ]] || { echo "mock bad-site server never came up on $port3" >&2; exit 1; }
bad_dest="$tmp/bad-dest"
set +e
bash "$repo_root/release/fetch-live-root.sh" "http://127.0.0.1:$port3" "$bad_dest" >/tmp/bad.log 2>&1
bad_rc=$?
set -e
(( bad_rc != 0 )) || { echo "a root installer failing its checksum was accepted" >&2; exit 1; }
grep -Fqi 'failed its own checksum' /tmp/bad.log \
  || { echo "checksum refusal did not report why" >&2; cat /tmp/bad.log >&2; exit 1; }

echo 'fetch-live-root.sh test passed.'
