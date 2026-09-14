#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_key() {
  local home="$1" expiry="$2"
  mkdir -m 700 "$home"
  gpg --batch --homedir "$home" --passphrase '' --quick-generate-key 'AgentOS test <test@example.invalid>' ed25519 cert 0 >/dev/null 2>&1
  local primary
  primary="$(gpg --batch --homedir "$home" --list-secret-keys --with-colons | awk -F: '$1=="fpr"{print $10;exit}')"
  gpg --batch --homedir "$home" --passphrase '' --quick-add-key "$primary" ed25519 sign "$expiry" >/dev/null 2>&1
  printf '%s %s\n' "$primary" "$(gpg --batch --homedir "$home" --list-secret-keys --with-colons | awk -F: '$1=="ssb"{print $5;exit}')"
}

make_repo() {
  local dir="$1" home="$2" subkey="$3"
  mkdir -p "$dir"
  printf package > "$dir/a.pkg.tar.zst"; printf database > "$dir/agentos.db.tar.gz"; printf '{}' > "$dir/release-manifest.json"
  gpg --batch --homedir "$home" --local-user "${subkey}!" --detach-sign "$dir/a.pkg.tar.zst"
  gpg --batch --homedir "$home" --local-user "${subkey}!" --detach-sign "$dir/agentos.db.tar.gz"
  gpg --batch --homedir "$home" --local-user "${subkey}!" --armor --detach-sign --output "$dir/release-manifest.json.asc" "$dir/release-manifest.json"
}

read -r primary subkey <<<"$(make_key "$tmp/healthy-home" 45d)"
make_repo "$tmp/healthy" "$tmp/healthy-home" "$subkey"
gpg --batch --homedir "$tmp/healthy-home" --armor --export "$primary" > "$tmp/healthy.asc"
AGENTOS_VERIFY_MIN_DAYS=30 bash "$root/repository/verify-repo.sh" "$tmp/healthy" "$tmp/healthy.asc"

read -r primary subkey <<<"$(make_key "$tmp/short-home" 5d)"
make_repo "$tmp/short" "$tmp/short-home" "$subkey"
gpg --batch --homedir "$tmp/short-home" --armor --export "$primary" > "$tmp/short.asc"
gpg --batch --homedir "$tmp/short-home" --verify "$tmp/short/agentos.db.tar.gz.sig" "$tmp/short/agentos.db.tar.gz"
if AGENTOS_VERIFY_MIN_DAYS=30 bash "$root/repository/verify-repo.sh" "$tmp/short" "$tmp/short.asc"; then exit 1; fi

printf tampered > "$tmp/healthy/agentos.db.tar.gz"
if bash "$root/repository/verify-repo.sh" "$tmp/healthy" "$tmp/healthy.asc"; then exit 1; fi
echo 'repository/verify-repo.sh validation passed.'
