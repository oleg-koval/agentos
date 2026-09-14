#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

assets=(
  AGENTS.md
  .github/PULL_REQUEST_TEMPLATE.md
  .github/ISSUE_TEMPLATE/bug_report.yml
  .github/ISSUE_TEMPLATE/feature_request.yml
  .github/ISSUE_TEMPLATE/support.yml
)

for asset in "${assets[@]}"; do
  test -s "$asset"
done

grep -Fq 'agentos health' AGENTS.md
grep -Fq 'agentos store list' AGENTS.md
grep -Fq 'agentos help' AGENTS.md
grep -Fq 'agentos agent start codex|claude|hermes|herdr' AGENTS.md
grep -Fq 'pacman -Ss NAME' AGENTS.md
grep -Fq 'ssh HOST' AGENTS.md
grep -Fq 'FreeRDP or direct user interaction' AGENTS.md
grep -Fq 'passwords, private keys' AGENTS.md
! grep -EqI 'github\.com[:/][A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' AGENTS.md
grep -Fq 'agentos-system' .agents/skills/agentos-system/SKILL.md

grep -Fq 'Closes #' .github/PULL_REQUEST_TEMPLATE.md
grep -Fq 'Acceptance criteria evidence' .github/PULL_REQUEST_TEMPLATE.md
grep -Fq 'Contributor identity and automation disclosure' .github/PULL_REQUEST_TEMPLATE.md

for form in .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/feature_request.yml; do
  grep -Eq '^name: .+' "$form"
  grep -Eq '^description: .+' "$form"
  for id in summary reproduction_context expected_behavior actual_behavior scope acceptance_criteria; do
    grep -Eq "^    id: $id$" "$form"
  done
done

grep -Eq '^name: Support request$' .github/ISSUE_TEMPLATE/support.yml
for id in summary goal context scope diagnostics desired_resolution acceptance_criteria; do
  grep -Eq "^    id: $id$" .github/ISSUE_TEMPLATE/support.yml
done

python3 - <<'PY'
from pathlib import Path
import yaml

for path in sorted(Path('.github/ISSUE_TEMPLATE').glob('*.yml')):
    document = yaml.safe_load(path.read_text(encoding='utf-8'))
    assert isinstance(document, dict), path
    assert isinstance(document.get('body'), list), path
PY

echo 'GitHub assets validation passed.'
