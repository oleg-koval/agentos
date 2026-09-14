#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 2 ]] || { echo 'Usage: verify-repo.sh <repo-dir> <public-key-file>' >&2; exit 2; }
repo_dir="$1"; pubkey="$2"; min_days="${AGENTOS_VERIFY_MIN_DAYS:-30}"
[[ -d "$repo_dir" && -f "$pubkey" ]] || { echo 'repository directory or public key file missing' >&2; exit 2; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
keyring="$tmp/gnupg"
mkdir -m 700 "$keyring"
gpg --batch --homedir "$keyring" --import "$pubkey" >/dev/null
targets=()
shopt -s nullglob
for artifact in "$repo_dir"/*.pkg.tar.zst; do targets+=("$artifact"); done
shopt -u nullglob
[[ -f "$repo_dir/agentos.db.tar.gz" ]] && targets+=("$repo_dir/agentos.db.tar.gz")
[[ -f "$repo_dir/release-manifest.json" ]] && targets+=("$repo_dir/release-manifest.json")
(( ${#targets[@]} )) || { echo "no signable artifacts found in $repo_dir" >&2; exit 2; }
signed=0
for artifact in "${targets[@]}"; do
  sig="${artifact}.sig"; [[ "$artifact" == *release-manifest.json ]] && sig="${artifact}.asc"
  [[ -f "$sig" ]] && ((signed += 1))
done
(( signed )) || { echo "No signatures present in $repo_dir; skipping verification (unsigned build)."; exit 0; }
(( signed == ${#targets[@]} )) || { echo 'refusing a partially-signed repository' >&2; exit 1; }
for artifact in "${targets[@]}"; do
  sig="${artifact}.sig"; [[ "$artifact" == *release-manifest.json ]] && sig="${artifact}.asc"
  gpg --batch --homedir "$keyring" --verify "$sig" "$artifact"
done
subkey="$(gpg --batch --homedir "$keyring" --list-keys --with-colons | awk -F: '$1=="sub"{print;exit}')"
[[ -n "$subkey" ]] || { echo 'public key has no signing subkey' >&2; exit 3; }
expiry="$(cut -d: -f7 <<<"$subkey")"
[[ -n "$expiry" ]] || { echo 'signing subkey has no expiry set' >&2; exit 3; }
days=$(( (expiry - $(date -u +%s)) / 86400 ))
echo "Signing subkey expires in ${days} day(s)."
(( days > min_days )) || { echo "signing subkey expires inside the ${min_days}-day threshold" >&2; exit 3; }
echo "All signatures valid; signing subkey has more than ${min_days} days remaining."
