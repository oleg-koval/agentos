#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fixture="$tmp/repo"

mkdir -p "$fixture/tests" "$fixture/packages/agentos-runtime" "$fixture/packages/agentos-shell"
cp "$repo_root/tests/package-version.sh" "$fixture/tests/package-version.sh"

write_pkgbuild() {
  local pkgrel="$1"
  printf 'pkgname=agentos-runtime\npkgver=1.0\npkgrel=%s\n' "$pkgrel" \
    > "$fixture/packages/agentos-runtime/PKGBUILD"
}

write_shell_pkgbuild() {
  local pkgrel="$1"
  printf 'pkgname=agentos-shell\npkgver=1.0\npkgrel=%s\n' "$pkgrel" \
    > "$fixture/packages/agentos-shell/PKGBUILD"
}

write_manifest() {
  local pkgrel="$1"
  printf '{"packages":[{"name":"agentos-runtime-1.0-%s-x86_64.pkg.tar.zst"},{"name":"agentos-shell-1.0-1-x86_64.pkg.tar.zst"}]}\n' "$pkgrel" \
    > "$fixture/live.json"
}

run_contract() {
  local comparison_base="${1:-base}"
  AGENTOS_LIVE_RELEASE_MANIFEST="$fixture/live.json" \
    AGENTOS_VERSION_BASE_REF="$comparison_base" \
    bash "$fixture/tests/package-version.sh"
}

expect_failure() {
  local expected="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    echo "package-version fixture unexpectedly passed: $expected" >&2
    exit 1
  fi
  grep -Fq "$expected" <<< "$output" || {
    echo "package-version fixture failed for the wrong reason: $output" >&2
    exit 1
  }
}

write_pkgbuild 1
write_shell_pkgbuild 1
write_manifest 1
git -C "$fixture" init -q
git -C "$fixture" config user.name 'AgentOS Test'
git -C "$fixture" config user.email 'agentos-test@example.invalid'
git -C "$fixture" add .
git -C "$fixture" commit -qm 'base'
git -C "$fixture" branch base

# Equality is valid when only non-runtime content changes.
printf 'friend-facing docs\n' > "$fixture/README.md"
git -C "$fixture" add README.md
git -C "$fixture" commit -qm 'docs only'
run_contract >/dev/null

# An unchanged package may equal stable, but it may never trail stable.
write_manifest 2
expect_failure 'runtime package 1.0-1 is older than stable 1.0-2' run_contract
write_manifest 1

# A missing comparison base must not silently disable the runtime-input guard.
expect_failure 'package-version comparison base is unavailable: missing-base' \
  env AGENTOS_LIVE_RELEASE_MANIFEST="$fixture/live.json" \
    AGENTOS_VERSION_BASE_REF=missing-base bash "$fixture/tests/package-version.sh"
grep -Fq 'git fetch --no-tags origin main:refs/remotes/origin/main' \
  "$repo_root/.github/workflows/ci.yml"

# Runtime changes require both a package metadata diff and a version newer than stable.
mkdir -p "$fixture/core"
printf 'runtime change\n' > "$fixture/core/runtime.txt"
git -C "$fixture" add core/runtime.txt
git -C "$fixture" commit -qm 'runtime change without package bump'
expect_failure 'runtime inputs changed without advancing' run_contract

write_pkgbuild 2
git -C "$fixture" add packages/agentos-runtime/PKGBUILD
git -C "$fixture" commit -qm 'advance runtime package'
write_manifest 2
expect_failure 'runtime package 1.0-2 is not newer than stable 1.0-2' run_contract
write_manifest 1
run_contract >/dev/null

# Shell inputs have the same package-version coupling.
base="$(git -C "$fixture" rev-parse HEAD)"
printf 'shell change\n' > "$fixture/agentos-home.sh"
git -C "$fixture" add agentos-home.sh
git -C "$fixture" commit -qm 'shell change without package bump'
expect_failure 'shell inputs changed without advancing' env \
  AGENTOS_VERSION_BASE_REF="$base" AGENTOS_LIVE_RELEASE_MANIFEST="$fixture/live.json" \
  bash "$fixture/tests/package-version.sh"
write_shell_pkgbuild 2
git -C "$fixture" add packages/agentos-shell/PKGBUILD
git -C "$fixture" commit -qm 'advance shell package'
run_contract "$base" >/dev/null

echo 'Package version fixture tests passed.'
