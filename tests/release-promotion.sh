#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
gnupg_home="$tmp/gnupg"
trap 'rm -rf "$tmp"' EXIT
mkdir -m 700 "$gnupg_home"

gpg --batch --homedir "$gnupg_home" --passphrase '' --quick-generate-key \
  'AgentOS release test <release-test@example.invalid>' rsa2048 sign 1d >/dev/null 2>&1
key_id="$(gpg --batch --homedir "$gnupg_home" --list-secret-keys --with-colons | awk -F: '$1 == "fpr" { print $10; exit }')"

source="$tmp/source"
mkdir -p "$source"
printf 'package bytes\n' > "$source/agentos-runtime-1.0.0-1-x86_64.pkg.tar.zst"
printf 'database bytes\n' > "$source/agentos.db.tar.gz"
printf 'files bytes\n' > "$source/agentos.files.tar.gz"
printf 'bootstrap bytes\n' > "$tmp/agentos-vps-install.sh"
cat > "$source/release-manifest.json" <<'JSON'
{"schema":"agentos.release/v1","channel":"edge","version":"0.1.0","commit":"0123456789abcdef0123456789abcdef01234567","generated_at":"2026-08-26T00:00:00Z","database":{"name":"agentos.db.tar.gz","sha256":"placeholder"},"bootstrap":{"name":"agentos-vps-install.sh","sha256":"placeholder","size":17},"packages":[]}
JSON
jq --arg sha "$(sha256sum "$source/agentos.db.tar.gz" | awk '{print $1}')" \
  --arg bootstrap_sha "$(sha256sum "$tmp/agentos-vps-install.sh" | awk '{print $1}')" \
  '.database.sha256 = $sha | .bootstrap.sha256 = $bootstrap_sha' "$source/release-manifest.json" > "$source/manifest.tmp"
mv "$source/manifest.tmp" "$source/release-manifest.json"
sha256sum "$source/release-manifest.json" | sed 's#  .*/#  #' > "$source/release-manifest.json.sha256"
for artifact in agentos-runtime-1.0.0-1-x86_64.pkg.tar.zst agentos.db.tar.gz agentos.files.tar.gz; do
  gpg --batch --homedir "$gnupg_home" --local-user "$key_id" --detach-sign "$source/$artifact"
done
gpg --batch --homedir "$gnupg_home" --local-user "$key_id" --armor --detach-sign \
  --output "$source/release-manifest.json.asc" "$source/release-manifest.json"

beta="$tmp/beta"
AGENTOS_SIGN_KEY="$key_id" GNUPGHOME="$gnupg_home" \
  bash "$repo_root/release/promote-repository.sh" "$source" beta "$beta" 12345

jq -e '
  .channel == "beta" and
  .commit == "0123456789abcdef0123456789abcdef01234567" and
  .promotion.from_channel == "edge" and
  .promotion.source_run_id == "12345"
' "$beta/release-manifest.json" >/dev/null
cmp "$source/agentos-runtime-1.0.0-1-x86_64.pkg.tar.zst" "$beta/agentos-runtime-1.0.0-1-x86_64.pkg.tar.zst"
cmp "$source/agentos.db.tar.gz" "$beta/agentos.db.tar.gz"
cmp "$source/agentos.files.tar.gz" "$beta/agentos.files.tar.gz"
[[ "$(jq -er '.bootstrap.sha256' "$beta/release-manifest.json")" == \
  "$(sha256sum "$tmp/agentos-vps-install.sh" | awk '{print $1}')" ]]
(cd "$beta" && sha256sum -c release-manifest.json.sha256 >/dev/null)
gpg --batch --homedir "$gnupg_home" --verify "$beta/release-manifest.json.asc" "$beta/release-manifest.json" >/dev/null 2>&1

stable="$tmp/stable"
AGENTOS_SIGN_KEY="$key_id" GNUPGHOME="$gnupg_home" bash "$repo_root/release/promote-repository.sh" "$beta" stable "$stable" 67890
jq -e '
  .channel == "stable" and
  .commit == "0123456789abcdef0123456789abcdef01234567" and
  .promotion.from_channel == "beta" and
  .promotion.source_run_id == "67890"
' "$stable/release-manifest.json" >/dev/null
cmp "$beta/agentos-runtime-1.0.0-1-x86_64.pkg.tar.zst" "$stable/agentos-runtime-1.0.0-1-x86_64.pkg.tar.zst"
gpg --batch --homedir "$gnupg_home" --verify "$stable/release-manifest.json.asc" "$stable/release-manifest.json" >/dev/null 2>&1

if AGENTOS_SIGN_KEY="$key_id" GNUPGHOME="$gnupg_home" \
  bash "$repo_root/release/promote-repository.sh" "$source" stable "$tmp/invalid" 12345 >/dev/null 2>&1; then
  echo 'stable promotion accepted an edge artifact' >&2
  exit 1
fi

echo 'Release promotion validation passed.'
