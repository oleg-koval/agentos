#!/usr/bin/env bash
set -euo pipefail

# The site root advertises the STABLE installer, which is what every install
# document points at. deploy-pages replaces the whole site on every publish and
# fetch-live-channel.sh only restores per-channel directories, so a beta or edge
# publish has to restore the live root files itself. Without this the root
# installer would either be replaced by a pre-release build or disappear.
#
# Exit 0 with an empty destination means the site has never published a root.

if [[ $# -ne 2 ]]; then
  echo "usage: fetch-live-root.sh <pages_base_url> <dest_dir>" >&2
  exit 2
fi
base_url="$1"
dest_dir="$2"

mkdir -p "$dest_dir"

installer="$dest_dir/agentos-vps-install.sh"
status="$(curl -sSL -w '%{http_code}' -o "$installer" "$base_url/agentos-vps-install.sh")"
if [[ "$status" == "404" ]]; then
  rm -f "$installer"
  echo "no live site root at $base_url; treating as never-published" >&2
  exit 0
fi
if [[ "$status" != "200" || ! -s "$installer" ]]; then
  echo "cannot restore live root (HTTP $status or empty response); refusing publication" >&2
  exit 1
fi

fetch() {
  local name="$1"
  local required="${2:-required}"
  local code
  code="$(curl -sSL -w '%{http_code}' -o "$dest_dir/$name" "$base_url/$name")"
  if [[ "$code" != "200" ]]; then
    rm -f "$dest_dir/$name"
    [[ "$required" == optional && "$code" == 404 ]] || { echo "failed to fetch live root file: $name (HTTP $code)" >&2; exit 1; }
  fi
}

fetch agentos-vps-install.sh.sha256
fetch agentos-repo-public.asc optional
fetch fingerprint.txt optional

# Restoring an installer nobody can verify is worse than restoring none, so the
# checksum is a hard gate rather than a warning.
(cd "$dest_dir" && sha256sum -c agentos-vps-install.sh.sha256 >/dev/null) \
  || { echo "live root installer failed its own checksum; refusing to republish it" >&2; exit 1; }

# curl does not preserve the published mode, and the installer is fetched by
# people who then run it.
chmod 755 "$installer"

echo "Restored the live site root into $dest_dir"
