#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: pages-overlay.sh <site_root> <stable|beta|edge> <channel_content_dir>" >&2
  exit 2
fi
site_root="$1"
channel="$2"
content_dir="$3"

case "$channel" in
  stable|beta|edge) ;;
  *) echo "channel must be stable, beta, or edge" >&2; exit 2 ;;
esac

[[ -d "$content_dir" ]] || { echo "channel content directory not found: $content_dir" >&2; exit 1; }

mkdir -p "$site_root"
rm -rf "${site_root:?}/${channel}"
mkdir -p "$site_root/$channel"
cp -a "$content_dir"/. "$site_root/$channel"/

echo "Overlaid $channel into $site_root/$channel"
