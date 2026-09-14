#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$repo_root/release/fetch-live-channel.sh"
if command -v shellcheck >/dev/null 2>&1; then shellcheck -S error "$repo_root/release/fetch-live-channel.sh"; fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

site="$tmp/site"
mkdir -p "$site/beta"
echo "pkg-bytes" > "$site/beta/agentos-runtime-1.pkg.tar.zst"
echo "sig-bytes" > "$site/beta/agentos-runtime-1.pkg.tar.zst.sig"
echo "db-bytes"  > "$site/beta/agentos.db.tar.gz"
echo "db-sig"    > "$site/beta/agentos.db.tar.gz.sig"
echo "files-bytes" > "$site/beta/agentos.files.tar.gz"
echo "files-sig"   > "$site/beta/agentos.files.tar.gz.sig"
cat > "$site/beta/release-manifest.json" <<'EOF'
{"schema":"agentos.release/v1","channel":"beta","packages":[{"name":"agentos-runtime-1.pkg.tar.zst"}],"database":{"name":"agentos.db.tar.gz"}}
EOF
echo "manifest-sha" > "$site/beta/release-manifest.json.sha256"
echo "manifest-sig" > "$site/beta/release-manifest.json.asc"

port=18453
(cd "$site" && python3 -m http.server "$port" >/tmp/fetch-live-channel-server.log 2>&1) &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
for _ in $(seq 1 20); do
  curl -sSf "http://127.0.0.1:$port/beta/release-manifest.json" >/dev/null 2>&1 && break
  sleep 0.2
done

dest="$tmp/dest"
bash "$repo_root/release/fetch-live-channel.sh" "http://127.0.0.1:$port" beta "$dest"
[[ -f "$dest/agentos-runtime-1.pkg.tar.zst" ]] || { echo "package not fetched" >&2; exit 1; }
[[ -f "$dest/agentos-runtime-1.pkg.tar.zst.sig" ]] || { echo "package signature not fetched" >&2; exit 1; }
[[ -f "$dest/agentos.db.tar.gz" ]] || { echo "database not fetched" >&2; exit 1; }
[[ -f "$dest/release-manifest.json.asc" ]] || { echo "manifest signature not fetched" >&2; exit 1; }

never_published="$tmp/never-published"
bash "$repo_root/release/fetch-live-channel.sh" "http://127.0.0.1:$port" edge "$never_published"
[[ ! -d "$never_published" ]] || { echo "expected no directory for a never-published channel" >&2; exit 1; }

empty_site="$tmp/empty-site"
mkdir -p "$empty_site/stable"
cat > "$empty_site/stable/release-manifest.json" <<'EOF'
{"schema":"agentos.release/v1","channel":"stable","packages":[],"database":{"name":"agentos.db.tar.gz"}}
EOF
echo "manifest-sha" > "$empty_site/stable/release-manifest.json.sha256"
echo "manifest-sig" > "$empty_site/stable/release-manifest.json.asc"
echo "db-bytes" > "$empty_site/stable/agentos.db.tar.gz"
echo "db-sig"   > "$empty_site/stable/agentos.db.tar.gz.sig"
echo "files-bytes" > "$empty_site/stable/agentos.files.tar.gz"
echo "files-sig"   > "$empty_site/stable/agentos.files.tar.gz.sig"

empty_port=18454
(cd "$empty_site" && python3 -m http.server "$empty_port" >/tmp/fetch-live-channel-empty-server.log 2>&1) &
empty_server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; kill "$empty_server_pid" 2>/dev/null || true; kill "$fail_server_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
for _ in $(seq 1 20); do
  curl -sSf "http://127.0.0.1:$empty_port/stable/release-manifest.json" >/dev/null 2>&1 && break
  sleep 0.2
done

empty_dest="$tmp/empty-dest"
empty_rc=0
bash "$repo_root/release/fetch-live-channel.sh" "http://127.0.0.1:$empty_port" stable "$empty_dest" >/tmp/fetch-live-channel-empty.log 2>&1 || empty_rc=$?
[[ "$empty_rc" -eq 1 ]] || { echo "expected exit 1 for a live manifest with an empty packages array, got $empty_rc" >&2; exit 1; }

fail_site="$tmp/fail-site"
mkdir -p "$fail_site/stable"
echo "pkg-bytes" > "$fail_site/stable/agentos-runtime-1.pkg.tar.zst"
echo "sig-bytes" > "$fail_site/stable/agentos-runtime-1.pkg.tar.zst.sig"
echo "db-bytes"  > "$fail_site/stable/agentos.db.tar.gz"
echo "db-sig"    > "$fail_site/stable/agentos.db.tar.gz.sig"
echo "files-bytes" > "$fail_site/stable/agentos.files.tar.gz"
echo "files-sig"   > "$fail_site/stable/agentos.files.tar.gz.sig"
cat > "$fail_site/stable/release-manifest.json" <<'EOF'
{"schema":"agentos.release/v1","channel":"stable","packages":[{"name":"agentos-runtime-1.pkg.tar.zst"}],"database":{"name":"agentos.db.tar.gz"}}
EOF
echo "manifest-sha" > "$fail_site/stable/release-manifest.json.sha256"
# deliberately omit release-manifest.json.asc so a required file 404s

fail_port=18455
(cd "$fail_site" && python3 -m http.server "$fail_port" >/tmp/fetch-live-channel-fail-server.log 2>&1) &
fail_server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; kill "$empty_server_pid" 2>/dev/null || true; kill "$fail_server_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
for _ in $(seq 1 20); do
  curl -sSf "http://127.0.0.1:$fail_port/stable/release-manifest.json" >/dev/null 2>&1 && break
  sleep 0.2
done

fail_dest="$tmp/fail-dest"
fail_rc=0
bash "$repo_root/release/fetch-live-channel.sh" "http://127.0.0.1:$fail_port" stable "$fail_dest" >/tmp/fetch-live-channel-fail.log 2>&1 || fail_rc=$?
[[ "$fail_rc" -eq 1 ]] || { echo "expected exit 1 when a required live file 404s, got $fail_rc" >&2; exit 1; }
grep -Fq 'failed to fetch live file: release-manifest.json.asc (HTTP 404)' /tmp/fetch-live-channel-fail.log || { echo "expected the real 404 message on stderr" >&2; exit 1; }

echo "fetch-live-channel.sh test passed."
