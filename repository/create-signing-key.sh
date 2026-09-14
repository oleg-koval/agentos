#!/usr/bin/env bash
# Create an AgentOS repository signing key outside CI. The private export is
# intentionally local-only and must be moved into the CI secret store manually.
set -euo pipefail

OUT="${1:-$PWD/agentos-signing-key}"
NAME="${AGENTOS_SIGNING_NAME:-AgentOS Repository Signing}"
EMAIL="${AGENTOS_SIGNING_EMAIL:-agentos-repository@local}"
SUBKEY_EXPIRE="${AGENTOS_SIGNING_SUBKEY_EXPIRE:-2y}"

command -v gpg >/dev/null 2>&1 || { echo 'gpg is required.' >&2; exit 1; }
mkdir -p "$OUT"; chmod 700 "$OUT"
GNUPGHOME="$OUT/gnupg"; export GNUPGHOME
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"

if gpg --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec:'; then
  echo "A secret key already exists in $GNUPGHOME; refusing to overwrite it." >&2
  exit 1
fi

uid="$NAME <$EMAIL>"

# The primary key is certify-only and never expires: it is the trust anchor
# pinned into release/repository.env for the life of the distro. gpg's quick
# interface spells "never expires" as the keyword "never" (the classic batch
# generator spells the same thing "Expire-Date: 0"; both mean no expiration).
gpg --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key "$uid" ed25519 cert never

fingerprint="$(gpg --list-secret-keys --with-colons | awk -F: '$1=="fpr"{print $10;exit}')"
[[ -n "$fingerprint" ]] || { echo 'Could not determine primary key fingerprint.' >&2; exit 1; }

# Only the signing subkey expires. Renewal extends this subkey
# (gpg --quick-set-expire) and re-publishes the public half; the primary
# fingerprint above never changes, so no client ever has to re-trust anything.
gpg --batch --pinentry-mode loopback --passphrase '' \
  --quick-add-key "$fingerprint" ed25519 sign "$SUBKEY_EXPIRE"

gpg --armor --export "$fingerprint" > "$OUT/agentos-repo-public.asc"
gpg --batch --pinentry-mode loopback --passphrase '' \
  --armor --export-secret-keys "$fingerprint" > "$OUT/agentos-repo-private.asc"
printf '%s\n' "$fingerprint" > "$OUT/fingerprint.txt"
chmod 600 "$OUT/agentos-repo-private.asc" "$OUT/fingerprint.txt"
chmod 644 "$OUT/agentos-repo-public.asc"

cat <<EOF
AgentOS repository signing key created.

Primary fingerprint (trust anchor, never expires):
  $fingerprint

Signing subkey expires in: $SUBKEY_EXPIRE

Public key (primary + signing subkey):
  $OUT/agentos-repo-public.asc

PRIVATE KEY:
  $OUT/agentos-repo-private.asc

Next actions:
  1. Store the private key as GitHub Actions secret AGENTOS_GPG_PRIVATE_KEY.
  2. Store the PRIMARY fingerprint ($fingerprint) as GitHub Actions secret AGENTOS_GPG_KEY_ID.
  3. Commit $OUT/agentos-repo-public.asc into the tree as release/agentos-signing.asc.
  4. Set AGENTOS_SIGNING_FINGERPRINT=$fingerprint in release/repository.env.
  5. Back up the private key offline. Do not commit it.
EOF
