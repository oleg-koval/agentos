#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANNEL="${1:-edge}"
REPO_DIR="${2:-$ROOT/out/repo/x86_64}"
OUT="${3:-$REPO_DIR/release-manifest.json}"
SIGN_KEY="${AGENTOS_SIGN_KEY:-}"
BOOTSTRAP="${AGENTOS_BOOTSTRAP:-}"
LOG_DIR="${AGENTOS_RELEASE_LOG_DIR:-$ROOT}"

case "$CHANNEL" in stable|beta|edge);; *) echo 'channel must be stable, beta, or edge' >&2; exit 2;; esac
[[ -d "$REPO_DIR" ]] || { echo "repository directory not found: $REPO_DIR" >&2; exit 1; }
channel_file="$ROOT/release/channels/$CHANNEL.json"
[[ -f "$channel_file" ]] || { echo "channel metadata missing: $channel_file" >&2; exit 1; }

version="$(jq -r '.version' "$channel_file")"
commit="${AGENTOS_BUILD_COMMIT:-}"
if [[ -z "$commit" ]]; then
  commit="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
fi
[[ "$commit" =~ ^[[:xdigit:]]{40}$ ]] || {
  echo 'release build commit must be a full 40-character Git SHA' >&2
  exit 1
}
generated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

REPO_BASE_URL="${AGENTOS_REPO_BASE_URL:-}"
if [[ -z "${AGENTOS_REPO_BASE_URL+x}" && -f "$ROOT/release/repository.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/release/repository.env"
  REPO_BASE_URL="${AGENTOS_REPO_BASE_URL:-}"
fi
[[ -n "$REPO_BASE_URL" ]] || { echo 'AGENTOS_REPO_BASE_URL is required (set directly or via release/repository.env)' >&2; exit 1; }

TOOL_VERSIONS_FILE="${AGENTOS_TOOL_VERSIONS_FILE:-$ROOT/release/tool-versions.json}"
[[ -f "$TOOL_VERSIONS_FILE" ]] || { echo "tool versions file not found: $TOOL_VERSIONS_FILE" >&2; exit 1; }
tools_json="$(cat "$TOOL_VERSIONS_FILE")"

packages='[]'
shopt -s nullglob
for pkg in "$REPO_DIR"/*.pkg.tar.zst; do
  name="$(basename "$pkg")"
  sha="$(sha256sum "$pkg" | awk '{print $1}')"
  size="$(wc -c < "$pkg" | tr -d '[:space:]')"
  packages="$(jq -c --arg name "$name" --arg sha "$sha" --argjson size "$size" '. + [{name:$name,sha256:$sha,size:$size}]' <<<"$packages")"
done
shopt -u nullglob
(( $(jq 'length' <<<"$packages") > 0 )) || { echo 'no packages found for manifest' >&2; exit 1; }

db="$REPO_DIR/agentos.db.tar.gz"
[[ -f "$db" ]] || { echo 'agentos.db.tar.gz missing' >&2; exit 1; }
db_sha="$(sha256sum "$db" | awk '{print $1}')"

bootstrap='null'
if [[ -n "$BOOTSTRAP" ]]; then
  [[ -f "$BOOTSTRAP" ]] || { echo "bootstrap asset not found: $BOOTSTRAP" >&2; exit 1; }
  bootstrap_name="$(basename "$BOOTSTRAP")"
  bootstrap_sha="$(sha256sum "$BOOTSTRAP" | awk '{print $1}')"
  bootstrap_size="$(wc -c < "$BOOTSTRAP" | tr -d '[:space:]')"
  bootstrap="$(jq -nc --arg name "$bootstrap_name" --arg sha "$bootstrap_sha" --argjson size "$bootstrap_size" '{name:$name,sha256:$sha,size:$size}')"
fi

notes='[]'
while IFS= read -r subject; do
  [[ -n "$subject" ]] || continue
  kind=chore
  text="$subject"
  if [[ "$subject" =~ ^([A-Za-z]+)(\!)?(\([^\)]*\))?:[[:space:]]*(.*)$ ]]; then
    type="${BASH_REMATCH[1],,}"
    bang="${BASH_REMATCH[2]}"
    text="${BASH_REMATCH[4]}"
    if [[ -n "$bang" ]]; then kind=breaking; else
      case "$type" in feat) kind=feature ;; fix) kind=fix ;; security) kind=security ;; esac
    fi
  fi
  notes="$(jq -c --arg kind "$kind" --arg text "$text" '. + [{kind:$kind,text:$text}]' <<<"$notes")"
done < <(git -C "$LOG_DIR" log -15 --pretty='%s' 2>/dev/null || true)

jq -n \
  --arg schema 'agentos.release/v2' \
  --arg channel "$CHANNEL" \
  --arg version "$version" \
  --arg commit "$commit" \
  --arg generated_at "$generated" \
  --arg database_sha256 "$db_sha" \
  --arg repository_url "$REPO_BASE_URL" \
  --argjson bootstrap "$bootstrap" \
  --argjson packages "$packages" \
  --argjson tools "$tools_json" \
  --argjson notes "$notes" \
  '{schema:$schema,channel:$channel,version:$version,commit:$commit,generated_at:$generated_at,database:{name:"agentos.db.tar.gz",sha256:$database_sha256},bootstrap:$bootstrap,packages:$packages,repository_url:$repository_url,tools:$tools,notes:$notes}' > "$OUT"

printf '%s  %s\n' "$(sha256sum "$OUT" | awk '{print $1}')" "$(basename "$OUT")" > "$OUT.sha256"
if [[ -n "$SIGN_KEY" ]]; then
  gpg --batch --yes --armor --detach-sign --local-user "$SIGN_KEY" --output "$OUT.asc" "$OUT"
fi

{
  printf 'AgentOS %s %s\n' "$CHANNEL" "$version"
  printf 'Commit: %s\nGenerated: %s\n\n' "$commit" "$generated"
  git -C "$LOG_DIR" log -15 --pretty='- %h %s' 2>/dev/null || true
} > "$REPO_DIR/release-notes.txt"

echo "Release manifest written to $OUT"
