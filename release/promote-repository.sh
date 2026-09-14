#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="${1:-}"
TARGET_CHANNEL="${2:-}"
OUT_DIR="${3:-}"
SOURCE_RUN_ID="${4:-${AGENTOS_PROMOTION_SOURCE_RUN_ID:-}}"
SIGN_KEY="${AGENTOS_SIGN_KEY:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ -n "$SOURCE_DIR" && -n "$TARGET_CHANNEL" && -n "$OUT_DIR" ]] || {
  echo 'usage: promote-repository.sh SOURCE_DIR beta|stable OUT_DIR SOURCE_RUN_ID' >&2
  exit 2
}
[[ "$SOURCE_DIR" != "$OUT_DIR" ]] || {
  echo 'source and output directories must differ' >&2
  exit 2
}
[[ -d "$SOURCE_DIR" ]] || { echo "source repository not found: $SOURCE_DIR" >&2; exit 1; }
[[ -n "$SIGN_KEY" ]] || { echo 'AGENTOS_SIGN_KEY is required for promotion' >&2; exit 1; }
[[ "$SOURCE_RUN_ID" =~ ^[0-9]+$ ]] || {
  echo 'promotion source run ID must be numeric' >&2
  exit 1
}

case "$TARGET_CHANNEL" in
  beta) expected_source_channel=edge ;;
  stable) expected_source_channel=beta ;;
  *) echo 'promotion target must be beta or stable' >&2; exit 2 ;;
esac

manifest="$SOURCE_DIR/release-manifest.json"
manifest_signature="$manifest.asc"
manifest_checksum="$manifest.sha256"
[[ -f "$manifest" && -f "$manifest_signature" && -f "$manifest_checksum" ]] || {
  echo 'source repository is missing signed release manifest artifacts' >&2
  exit 1
}

(cd "$SOURCE_DIR" && sha256sum -c "$(basename "$manifest_checksum")" >/dev/null)
gpg --batch --verify "$manifest_signature" "$manifest" >/dev/null

source_channel="$(jq -er '.channel' "$manifest")"
source_version="$(jq -er '.version' "$manifest")"
source_commit="$(jq -er '.commit' "$manifest")"
[[ "$source_channel" == "$expected_source_channel" ]] || {
  echo "source channel $source_channel cannot promote to $TARGET_CHANNEL" >&2
  exit 1
}
[[ "$source_commit" =~ ^[[:xdigit:]]{40}$ ]] || {
  echo 'source manifest has an invalid commit' >&2
  exit 1
}
bootstrap_name="$(jq -r '.bootstrap.name // empty' "$manifest")"
if [[ -n "$bootstrap_name" ]]; then
  bootstrap_source="$(dirname "$SOURCE_DIR")/$bootstrap_name"
  [[ -f "$bootstrap_source" ]] || { echo "source repository is missing bootstrap asset: $bootstrap_name" >&2; exit 1; }
  bootstrap_sha="$(sha256sum "$bootstrap_source" | awk '{print $1}')"
  [[ "$bootstrap_sha" == "$(jq -er '.bootstrap.sha256' "$manifest")" ]] || {
    echo "bootstrap asset checksum does not match the signed release manifest" >&2
    exit 1
  }
fi
target_version="$(jq -er '.version' "$ROOT/release/channels/$TARGET_CHANNEL.json")"
[[ "$source_version" == "$target_version" ]] || {
  echo "source version $source_version does not match $TARGET_CHANNEL version $target_version" >&2
  exit 1
}

shopt -s nullglob
packages=("$SOURCE_DIR"/*.pkg.tar.zst)
shopt -u nullglob
(( ${#packages[@]} > 0 )) || { echo 'source repository has no packages' >&2; exit 1; }
for pkg in "${packages[@]}"; do
  [[ -f "$pkg.sig" ]] || { echo "missing package signature: $pkg.sig" >&2; exit 1; }
  gpg --batch --verify "$pkg.sig" "$pkg" >/dev/null
done
for database in agentos.db.tar.gz agentos.files.tar.gz; do
  [[ -f "$SOURCE_DIR/$database" && -f "$SOURCE_DIR/$database.sig" ]] || {
    echo "missing signed repository database: $database" >&2
    exit 1
  }
  gpg --batch --verify "$SOURCE_DIR/$database.sig" "$SOURCE_DIR/$database" >/dev/null
done

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp -a "$SOURCE_DIR"/. "$OUT_DIR"/

source_manifest_sha256="$(sha256sum "$manifest" | awk '{print $1}')"
tmp_manifest="$(mktemp)"
trap 'rm -f "$tmp_manifest"' EXIT
jq --arg channel "$TARGET_CHANNEL" --arg source_channel "$source_channel" --arg source_manifest_sha256 "$source_manifest_sha256" --arg source_run_id "$SOURCE_RUN_ID" '.channel = $channel | .promotion = {from_channel: $source_channel, source_manifest_sha256: $source_manifest_sha256, source_run_id: $source_run_id}' "$manifest" > "$tmp_manifest"
mv "$tmp_manifest" "$OUT_DIR/release-manifest.json"
sha256sum "$OUT_DIR/release-manifest.json" | sed 's#  .*/#  #' > "$OUT_DIR/release-manifest.json.sha256"
gpg --batch --yes --armor --detach-sign --local-user "$SIGN_KEY" \
  --output "$OUT_DIR/release-manifest.json.asc" "$OUT_DIR/release-manifest.json"

{
  printf 'AgentOS %s %s\n' "$TARGET_CHANNEL" "$source_version"
  printf 'Promoted from: %s artifact\nSource run: %s\nCommit: %s\n' \
    "$source_channel" "$SOURCE_RUN_ID" "$source_commit"
} > "$OUT_DIR/release-notes.txt"

echo "Promoted $source_channel artifact from run $SOURCE_RUN_ID to $TARGET_CHANNEL"
