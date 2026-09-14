#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$repo_root/release/assemble-site-root.sh"
if command -v shellcheck >/dev/null 2>&1; then shellcheck -S error "$repo_root/release/assemble-site-root.sh"; fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A live site whose root is the stable installer.
live="$tmp/live"
mkdir -p "$live"
printf '#!/usr/bin/env bash\necho live-stable-installer\n' > "$live/agentos-vps-install.sh"
(cd "$live" && sha256sum agentos-vps-install.sh > agentos-vps-install.sh.sha256)
echo "live-public-key" > "$live/agentos-repo-public.asc"
echo "LIVEFINGERPRINT" > "$live/fingerprint.txt"

# The build being promoted, which is a different installer.
build="$tmp/build"
mkdir -p "$build"
printf '#!/usr/bin/env bash\necho promoted-build-installer\n' > "$build/agentos-vps-install.sh"
(cd "$build" && sha256sum agentos-vps-install.sh > agentos-vps-install.sh.sha256)
echo "build-public-key" > "$build/agentos-repo-public.asc"
echo "BUILDFINGERPRINT" > "$build/fingerprint.txt"

port=18461
(cd "$live" && exec python3 -m http.server "$port" >/tmp/assemble-site-root-live.log 2>&1) &
live_pid=$!
trap 'kill "$live_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
ready=''
for _ in $(seq 1 40); do
  curl -sSf "http://127.0.0.1:$port/agentos-vps-install.sh" >/dev/null 2>&1 && { ready=yes; break; }
  sleep 0.2
done
[[ -n "$ready" ]] || { echo "mock live server never came up on $port" >&2; exit 1; }

# Case 1: a stable promotion replaces the root with its own build.
site="$tmp/site-stable"
bash "$repo_root/release/assemble-site-root.sh" stable "http://127.0.0.1:$port" "$build" "$site" >/dev/null
grep -Fq 'promoted-build-installer' "$site/agentos-vps-install.sh" \
  || { echo "a stable promotion did not publish its own installer" >&2; exit 1; }
grep -Fq 'BUILDFINGERPRINT' "$site/fingerprint.txt" \
  || { echo "a stable promotion did not publish its own fingerprint" >&2; exit 1; }
[[ -x "$site/agentos-vps-install.sh" ]] || { echo "published installer is not executable" >&2; exit 1; }
for asset in index.html install.html support.html styles.css robots.txt sitemap.xml og-agentos.svg og-agentos.png; do
  [[ -f "$site/$asset" ]] || { echo "published site is missing $asset" >&2; exit 1; }
done
grep -Fq '<link rel="canonical" href="https://oleg-koval.github.io/agentos/">' "$site/index.html" \
  || { echo 'published landing page has no canonical URL' >&2; exit 1; }
grep -Fq '"@type": "SoftwareApplication"' "$site/index.html" \
  || { echo 'published landing page has no SoftwareApplication structured data' >&2; exit 1; }
grep -Fq 'Sitemap: https://oleg-koval.github.io/agentos/sitemap.xml' "$site/robots.txt" \
  || { echo 'published robots.txt does not advertise the sitemap' >&2; exit 1; }

# Case 2: a beta promotion leaves the live stable root alone. This is the defect
# the script exists to prevent: publishing beta must not hand the documented
# install URL a pre-release installer, and must not delete it either.
for ch in beta edge; do
  site="$tmp/site-$ch"
  bash "$repo_root/release/assemble-site-root.sh" "$ch" "http://127.0.0.1:$port" "$build" "$site" >/dev/null
  grep -Fq 'live-stable-installer' "$site/agentos-vps-install.sh" \
    || { echo "a $ch promotion overwrote the stable root installer" >&2; exit 1; }
  ! grep -Fq 'promoted-build-installer' "$site/agentos-vps-install.sh" \
    || { echo "a $ch promotion published its own installer at the root" >&2; exit 1; }
  grep -Fq 'LIVEFINGERPRINT' "$site/fingerprint.txt" \
    || { echo "a $ch promotion overwrote the root fingerprint" >&2; exit 1; }
  [[ -x "$site/agentos-vps-install.sh" ]] || { echo "preserved installer is not executable" >&2; exit 1; }
  (cd "$site" && sha256sum -c agentos-vps-install.sh.sha256 >/dev/null) \
    || { echo "preserved root failed its own checksum" >&2; exit 1; }
done

# Case 3: before any stable release exists there is nothing to preserve, so a
# pre-release promotion seeds the root instead of publishing a site with no
# installer at the URL the docs advertise.
empty="$tmp/empty-live"
mkdir -p "$empty"
port2=18462
(cd "$empty" && exec python3 -m http.server "$port2" >/tmp/assemble-site-root-empty.log 2>&1) &
empty_pid=$!
trap 'kill "$live_pid" "$empty_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
ready=''
for _ in $(seq 1 40); do
  curl -sS "http://127.0.0.1:$port2/" >/dev/null 2>&1 && { ready=yes; break; }
  sleep 0.2
done
[[ -n "$ready" ]] || { echo "mock empty server never came up on $port2" >&2; exit 1; }
site="$tmp/site-first-beta"
bash "$repo_root/release/assemble-site-root.sh" beta "http://127.0.0.1:$port2" "$build" "$site" 2>/dev/null >/dev/null
grep -Fq 'promoted-build-installer' "$site/agentos-vps-install.sh" \
  || { echo "a first-ever beta promotion left the root without an installer" >&2; exit 1; }

# Case 4: a channel the promotion pipeline does not publish is rejected rather
# than silently treated as a pre-release.
set +e
bash "$repo_root/release/assemble-site-root.sh" none "http://127.0.0.1:$port" "$build" "$tmp/site-bogus" >/dev/null 2>&1
rc=$?
set -e
(( rc == 2 )) || { echo "an unpublishable channel was accepted (rc=$rc)" >&2; exit 1; }

echo 'assemble-site-root.sh test passed.'
