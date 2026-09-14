#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

docs=docs/vps-providers.md
installer=agentos-vps-install.sh

[[ -f "$docs" ]]
[[ -x "$installer" ]]

# Provider automation is intentionally outside the signed bootstrap. This
# credential-free contract keeps every provider profile aligned with the same
# host and safety requirements until a provider adapter is provisioned.
grep -Fq 'Arch Linux x86_64' "$docs"
grep -Fq 'systemd as PID 1' "$docs"
grep -Fq 'active SSH listener on TCP 22' "$docs"
grep -Fq 'non-root user' "$docs"
grep -Fq 'disk partitioning' "$docs"
grep -Fq 'Google Cloud, Arch x86_64, disposable VM' "$docs"
grep -Fq 'AWS Arch x86_64' "$docs"
grep -Fq 'Hetzner Arch x86_64' "$docs"

help="$(AGENTOS_VPS_TEST_MODE=1 bash "$installer" --help)"
grep -Fq -- '--yes' <<<"$help"
grep -Fq -- '--reset' <<<"$help"
grep -Fq 'already' <<<"$help"

if grep -Eq 'mkfs|wipefs|parted|fdisk|(^|[[:space:]])dd([[:space:]]|$)|StrictHostKeyChecking=no|UserKnownHostsFile=/dev/null|sshpass|ufw .*disable' "$installer"; then
  echo 'provider contract violated by destructive or access-bypassing bootstrap operation' >&2
  exit 1
fi

echo 'Provider contract validation passed.'
