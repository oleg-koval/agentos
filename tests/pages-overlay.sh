#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$repo_root/release/pages-overlay.sh"
if command -v shellcheck >/dev/null 2>&1; then shellcheck -S error "$repo_root/release/pages-overlay.sh"; fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

site="$tmp/site"
mkdir -p "$site/edge" "$site/beta" "$site/stable"
echo "edge-package-v1"   > "$site/edge/agentos-runtime-1.pkg.tar.zst"
echo "edge-manifest-v1"  > "$site/edge/release-manifest.json"
echo "beta-package-v1"   > "$site/beta/agentos-runtime-1.pkg.tar.zst"
echo "beta-manifest-v1"  > "$site/beta/release-manifest.json"
echo "stable-package-v1" > "$site/stable/agentos-runtime-1.pkg.tar.zst"
echo "stable-manifest-v1" > "$site/stable/release-manifest.json"
echo "signing-key-v1" > "$site/agentos-signing.asc"
echo "index-v1" > "$site/index.html"

tree_hash() {
  (cd "$1" && find . -type f | sort | xargs sha256sum) | sha256sum | awk '{print $1}'
}

edge_before="$(tree_hash "$site/edge")"
stable_before="$(tree_hash "$site/stable")"
signing_before="$(cat "$site/agentos-signing.asc")"
index_before="$(cat "$site/index.html")"

new_beta="$tmp/new-beta"
mkdir -p "$new_beta"
echo "beta-package-v2"  > "$new_beta/agentos-runtime-2.pkg.tar.zst"
echo "beta-manifest-v2" > "$new_beta/release-manifest.json"

bash "$repo_root/release/pages-overlay.sh" "$site" beta "$new_beta"

edge_after="$(tree_hash "$site/edge")"
stable_after="$(tree_hash "$site/stable")"
signing_after="$(cat "$site/agentos-signing.asc")"
index_after="$(cat "$site/index.html")"

[[ "$edge_before" == "$edge_after" ]] || { echo "edge channel changed during beta overlay" >&2; exit 1; }
[[ "$stable_before" == "$stable_after" ]] || { echo "stable channel changed during beta overlay" >&2; exit 1; }
[[ "$signing_before" == "$signing_after" ]] || { echo "top-level signing file changed during beta overlay" >&2; exit 1; }
[[ "$index_before" == "$index_after" ]] || { echo "top-level index.html changed during beta overlay" >&2; exit 1; }
[[ -f "$site/agentos-signing.asc" ]] || { echo "top-level signing file was removed during beta overlay" >&2; exit 1; }
[[ -f "$site/index.html" ]] || { echo "top-level index.html was removed during beta overlay" >&2; exit 1; }

[[ -f "$site/beta/agentos-runtime-2.pkg.tar.zst" ]] || { echo "beta overlay did not land the new package" >&2; exit 1; }
[[ ! -f "$site/beta/agentos-runtime-1.pkg.tar.zst" ]] || { echo "beta overlay left a stale package behind" >&2; exit 1; }
[[ "$(cat "$site/beta/release-manifest.json")" == "beta-manifest-v2" ]] || { echo "beta manifest was not overlaid" >&2; exit 1; }

status=0
bash "$repo_root/release/pages-overlay.sh" "$site" bogus "$new_beta" 2>"$tmp/err.txt" || status=$?
[[ $status -eq 2 ]] || { echo "expected exit code 2 for an invalid channel name, got $status" >&2; exit 1; }
grep -Fq 'channel must be stable, beta, or edge' "$tmp/err.txt"

status=0
bash "$repo_root/release/pages-overlay.sh" "$site" edge "$tmp/does-not-exist" 2>"$tmp/err2.txt" || status=$?
[[ $status -eq 1 ]] || { echo "expected exit code 1 for a missing content directory, got $status" >&2; exit 1; }
grep -Fq 'channel content directory not found' "$tmp/err2.txt"

status=0
bash "$repo_root/release/pages-overlay.sh" "$site" beta 2>"$tmp/err3.txt" || status=$?
[[ $status -eq 2 ]] || { echo "expected exit code 2 for wrong argument count, got $status" >&2; exit 1; }
grep -Fq 'usage: pages-overlay.sh <site_root> <stable|beta|edge> <channel_content_dir>' "$tmp/err3.txt"

echo "pages-overlay.sh test passed."
