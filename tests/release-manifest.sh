#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf 'package fixture\n' > "$tmp/agentos-runtime-1.0.0-1-x86_64.pkg.tar.zst"
printf 'database fixture\n' > "$tmp/agentos.db.tar.gz"
printf 'bootstrap fixture\n' > "$tmp/agentos-vps-install.sh"

commit='0123456789abcdef0123456789abcdef01234567'
AGENTOS_REPO_BASE_URL='https://example.invalid/agentos' \
  AGENTOS_BUILD_COMMIT="$commit" \
  AGENTOS_BOOTSTRAP="$tmp/agentos-vps-install.sh" \
  bash "$repo_root/release/build-manifest.sh" edge "$tmp"

jq -e --arg commit "$commit" \
  '.schema == "agentos.release/v2" and .commit == $commit and .bootstrap.name == "agentos-vps-install.sh" and (.bootstrap.sha256 | length == 64) and .repository_url == "https://example.invalid/agentos" and .tools.schema == "agentos.tools/v1" and (.notes | type == "array")' \
  "$tmp/release-manifest.json" >/dev/null
grep -Fqx "$(sha256sum "$tmp/release-manifest.json" | awk '{print $1}')  release-manifest.json" \
  "$tmp/release-manifest.json.sha256"
! grep -Fq '/' "$tmp/release-manifest.json.sha256"
(cd "$tmp" && sha256sum -c release-manifest.json.sha256 >/dev/null)

if AGENTOS_BUILD_COMMIT=unknown \
  bash "$repo_root/release/build-manifest.sh" edge "$tmp" "$tmp/invalid.json" 2>/dev/null; then
  echo 'release manifest accepted an invalid build commit' >&2
  exit 1
fi

if AGENTOS_REPO_BASE_URL='' AGENTOS_BUILD_COMMIT="$commit" AGENTOS_BOOTSTRAP="$tmp/agentos-vps-install.sh" \
  bash "$repo_root/release/build-manifest.sh" edge "$tmp" "$tmp/no-url.json" 2>/dev/null; then
  echo 'release manifest accepted a missing repository URL' >&2
  exit 1
fi

echo 'Release manifest validation passed.'
