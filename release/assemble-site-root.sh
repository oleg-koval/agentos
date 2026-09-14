#!/usr/bin/env bash
set -euo pipefail

# Decides what the published site root contains. The root advertises the STABLE
# installer, because that is the URL every install document points at, so only a
# stable promotion may replace it. deploy-pages replaces the whole site on every
# publish, so a beta or edge promotion has to put the live root back rather than
# leave it out.

if [[ $# -ne 4 ]]; then
  echo "usage: assemble-site-root.sh <stable|beta|edge> <pages_base_url> <build_dir> <site_dir>" >&2
  exit 2
fi
channel="$1"
base_url="$2"
build_dir="$3"
site_dir="$4"

case "$channel" in
  stable|beta|edge) ;;
  *) echo "channel must be stable, beta, or edge" >&2; exit 2 ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
site_source="$script_dir/../site"
mkdir -p "$site_dir"

publish_landing_page() {
  [[ -d "$site_source" ]] || { echo "landing page source is missing: $site_source" >&2; exit 1; }
  local asset
  local assets=(index.html install.html support.html styles.css robots.txt sitemap.xml og-agentos.svg og-agentos.png)
  for asset in "${assets[@]}"; do
    [[ -f "$site_source/$asset" ]] || { echo "landing page source is missing $asset" >&2; exit 1; }
    cp "$site_source/$asset" "$site_dir/$asset"
  done
}

seed_from_build() {
  local f
  for f in agentos-vps-install.sh agentos-vps-install.sh.sha256 agentos-repo-public.asc fingerprint.txt; do
    [[ -f "$build_dir/$f" ]] || { echo "build directory is missing $f" >&2; exit 1; }
    cp "$build_dir/$f" "$site_dir/$f"
  done
  # The CI artifact round-trip drops the executable bit, and this file is
  # fetched and then run by people.
  chmod 755 "$site_dir/agentos-vps-install.sh"
}

if [[ "$channel" == stable ]]; then
  seed_from_build
  echo "Site root seeded from the stable build"
else
  bash "$script_dir/fetch-live-root.sh" "$base_url" "$site_dir"
  if [[ -f "$site_dir/agentos-vps-install.sh" ]]; then
    echo "Site root preserved from the live stable release"
  else
    # Nothing is live yet. Seeding from a pre-release build keeps the documented
    # install URL working before the first stable release exists.
    seed_from_build
    echo "No live site root yet; seeded from the $channel build"
  fi
fi

publish_landing_page
test -x "$site_dir/agentos-vps-install.sh"
(cd "$site_dir" && sha256sum -c agentos-vps-install.sh.sha256 >/dev/null)
