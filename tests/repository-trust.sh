#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

env_file=release/repository.env
key_file=release/agentos-signing.asc
installer=agentos-vps-install.sh

[[ -f "$env_file" && -f "$key_file" && -f "$installer" ]] || {
  echo 'repository trust inputs are incomplete' >&2
  exit 1
}
# shellcheck disable=SC1091
source "$env_file"
[[ "$AGENTOS_REPO_BASE_URL" == https://* ]] || {
  echo 'repository base URL must use HTTPS' >&2
  exit 1
}
[[ "$AGENTOS_SIGNING_FINGERPRINT" =~ ^[[:xdigit:]]{40}$ ]] || {
  echo 'repository fingerprint must be a full 40-character value' >&2
  exit 1
}
actual="$(gpg --show-keys --with-colons "$key_file" | awk -F: '$1 == "fpr" {print $10; exit}')"
expected="$(printf '%s' "$AGENTOS_SIGNING_FINGERPRINT" | tr '[:lower:]' '[:upper:]')"
[[ "$actual" == "$expected" ]] || {
  echo "repository fingerprint drift: env=$expected key=$actual" >&2
  exit 1
}

# The standalone asset is published without release/repository.env. Its
# defaults must therefore agree with the canonical public trust inputs.
grep -Fqx "DEFAULT_REPO_BASE_URL='$AGENTOS_REPO_BASE_URL'" "$installer"
grep -Fqx "DEFAULT_FINGERPRINT='$expected'" "$installer"
grep -Fq 'DEFAULT_KEY_URL="${DEFAULT_REPO_BASE_URL}/agentos-signing.asc"' "$installer"
! grep -Fq '3060184CFC884D14CB1D54F9CA25144B4E4DBA8E' "$installer" README.md docs/vps-onboarding.md
! grep -Fq 'agentos-repo-public.asc' docs/vps-onboarding.md README.md
for document in README.md docs/vps-onboarding.md site/install.html; do
  grep -Fq "$expected" "$document" || {
    echo "canonical signing fingerprint is missing from $document" >&2
    exit 1
  }
done

echo 'Repository trust contract passed.'
