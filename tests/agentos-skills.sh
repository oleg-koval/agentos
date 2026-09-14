#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p \
  "$tmp/source/agentos-operator" \
  "$tmp/source/agentos-maintainer" \
  "$tmp/home/.claude/skills/agentos-operator"
printf 'operator\n' > "$tmp/source/agentos-operator/SKILL.md"
printf 'maintainer\n' > "$tmp/source/agentos-maintainer/SKILL.md"
printf 'user-owned\n' > "$tmp/home/.claude/skills/agentos-operator/SKILL.md"

HOME="$tmp/home" AGENTOS_SKILLS_SOURCE="$tmp/source" \
  bash -c 'script="$1"; set --; source "$script"; install_agentos_skills' bash "$repo_root/install-agent-tools.sh"

test -L "$tmp/home/.agents/skills/agentos-operator"
test -L "$tmp/home/.hermes/skills/agentos-maintainer"
grep -Fxq 'user-owned' "$tmp/home/.claude/skills/agentos-operator/SKILL.md"
first_target="$(readlink "$tmp/home/.agents/skills/agentos-operator")"

HOME="$tmp/home" AGENTOS_SKILLS_SOURCE="$tmp/source" \
  bash -c 'script="$1"; set --; source "$script"; install_agentos_skills' bash "$repo_root/install-agent-tools.sh" >/dev/null
test "$first_target" = "$(readlink "$tmp/home/.agents/skills/agentos-operator")"

echo 'AgentOS skill adapter idempotence and preservation passed.'
