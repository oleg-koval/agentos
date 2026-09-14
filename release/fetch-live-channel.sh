#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: fetch-live-channel.sh <pages_base_url> <stable|beta|edge> <dest_dir>" >&2
  exit 2
fi
base_url="$1"
channel="$2"
dest_dir="$3"

case "$channel" in
  stable|beta|edge) ;;
  *) echo "channel must be stable, beta, or edge" >&2; exit 2 ;;
esac

mkdir -p "$dest_dir"
manifest_file="$dest_dir/release-manifest.json"
status="$(curl -sSL -w '%{http_code}' -o "$manifest_file" "$base_url/$channel/release-manifest.json")"
if [[ "$status" == "404" ]]; then
  rm -rf "${dest_dir:?}"
  echo "no live manifest for channel $channel; treating as never-published" >&2
  exit 0
fi
if [[ "$status" != "200" || ! -s "$manifest_file" ]]; then
  echo "cannot restore live $channel channel (HTTP $status or empty response); refusing publication" >&2
  exit 1
fi

fetch() {
  local name="$1"
  local required="${2:-required}"
  local code
  code="$(curl -sSL -w '%{http_code}' -o "$dest_dir/$name" "$base_url/$channel/$name")"
  if [[ "$code" != "200" ]]; then
    rm -f "$dest_dir/$name"
    [[ "$required" == optional && "$code" == 404 ]] || { echo "failed to fetch live file: $name (HTTP $code)" >&2; exit 1; }
  fi
}

fetch release-manifest.json.sha256
fetch release-manifest.json.asc
fetch release-notes.txt optional
for base in agentos.db agentos.files; do
  fetch "$base.tar.gz"
  fetch "$base.tar.gz.sig"
  fetch "$base" optional
  fetch "$base.sig" optional
done
pkgs="$(jq -r '.packages[].name' "$manifest_file")"
[[ -n "$pkgs" ]] || { echo "live manifest for $channel lists no packages" >&2; exit 1; }
while IFS= read -r pkg; do
  fetch "$pkg"
  fetch "$pkg.sig"
done <<<"$pkgs"

echo "Fetched live $channel channel into $dest_dir"
