#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo/release"
mkdir -p "$tmp/repo/tasks"
printf 'private planning\n' > "$tmp/repo/tasks/plan.md"
cp "$repo_root/.gitattributes" "$tmp/repo/.gitattributes"
cp "$repo_root/release/export-source.sh" "$tmp/repo/release/"
git -C "$tmp/repo" init -q
printf 'reviewed\n' > "$tmp/repo/payload"
git -C "$tmp/repo" add .
git -C "$tmp/repo" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
commit="$(git -C "$tmp/repo" rev-parse HEAD)"
printf 'dirty\n' > "$tmp/repo/payload"
mkdir -p "$tmp/repo/.playwright-mcp"
printf 'private QA\n' > "$tmp/repo/.playwright-mcp/report"
bash "$tmp/repo/release/export-source.sh" "$commit" "$tmp/export"
[[ "$(cat "$tmp/export/payload")" == reviewed ]]
[[ "$(cat "$tmp/export/release/source-commit")" == "$commit" ]]
[[ ! -e "$tmp/export/.git" && ! -e "$tmp/export/.playwright-mcp" ]]
[[ ! -e "$tmp/export/tasks" ]]
if bash "$tmp/repo/release/export-source.sh" "$commit" "$tmp/export"; then
  echo 'Existing export must not be overwritten.' >&2; exit 1
fi
if bash "$tmp/repo/release/export-source.sh" missing-revision "$tmp/invalid"; then
  echo 'Invalid revision must fail.' >&2; exit 1
fi
[[ ! -e "$tmp/invalid" ]]
echo 'Committed source export passed.'
