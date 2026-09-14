#!/usr/bin/env bash
# Build a bootable AgentOS installer ISO from Arch's maintained releng profile.
set -euo pipefail

if [[ ${EUID} -eq 0 ]]; then
  echo 'Run build-agentos-iso as a normal user; it will sudo mkarchiso when required.' >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out_dir="${AGENTOS_ISO_OUT:-$repo_root/out}"
work_dir="${AGENTOS_ISO_WORK:-$repo_root/.build/archiso}"
profile="$work_dir/profile"
version="${AGENTOS_VERSION:-}"
source_rev="${AGENTOS_SOURCE_REV:?Set AGENTOS_SOURCE_REV to the reviewed commit to build}"
source_commit="$(git -C "$repo_root" rev-parse --verify "$source_rev^{commit}")"
[[ "$source_commit" == "$(git -C "$repo_root" rev-parse HEAD)" ]] || {
  echo 'Check out AGENTOS_SOURCE_REV before building.' >&2; exit 1;
}
[[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=no)" ]] || {
  echo 'Commit or isolate tracked changes before building.' >&2; exit 1;
}
channel="${AGENTOS_CHANNEL:-stable}"
case "$channel" in stable|beta|edge) ;; *) echo "Unsupported channel: $channel" >&2; exit 2 ;; esac
source_repository="${AGENTOS_REPO:?Set AGENTOS_REPO to the public HTTPS source repository}"
[[ "$source_repository" =~ ^https://[^/@[:space:]]+/[^[:space:]]+$ && "$source_repository" != *'?'* && "$source_repository" != *'#'* ]] || {
  echo 'AGENTOS_REPO must be a public HTTPS URL without credentials, query or fragment.' >&2; exit 2;
}
source_dir="$(mktemp -d)"
trap 'rm -rf "$source_dir"' EXIT
bash "$repo_root/release/export-source.sh" "$source_commit" "$source_dir/source"
printf '%s\n' "$channel" > "$source_dir/source/release/installer-channel"
printf '%s\n' "$source_repository" > "$source_dir/source/release/source-repository"

signed_repo_dir="${AGENTOS_SIGNED_REPO_DIR:-}"

command -v mkarchiso >/dev/null 2>&1 || sudo pacman -S --needed --noconfirm archiso

rm -rf "$work_dir"
mkdir -p "$work_dir" "$out_dir"
cp -a /usr/share/archiso/configs/releng "$profile"
package_cache="$work_dir/package-cache"
install_repo="$work_dir/install-repo"
mkdir -p "$package_cache"


brand_uefi_menu() {
  local entry
  local -a entries=()

  while IFS= read -r -d '' entry; do
    entries+=("$entry")
  done < <(find "$profile" -type f -path '*/loader/entries/*.conf' -print0)

  ((${#entries[@]} > 0)) || {
    echo 'archiso releng profile has no UEFI loader entries to brand.' >&2
    exit 1
  }

  for entry in "${entries[@]}"; do
    sed -i \
      -e 's/^title[[:space:]]\+Arch Linux install medium/title AgentOS installer/' \
      -e 's/^title[[:space:]]\+Memtest86+/title AgentOS memory test/' \
      -e 's/^title[[:space:]]\+EFI Shell/title AgentOS EFI shell/' \
      -e 's/^title[[:space:]]\+Reboot Into Firmware Interface/title Reboot into firmware/' \
      "$entry"
  done
}

brand_uefi_menu

cat >> "$profile/packages.x86_64" <<'EOF'
arch-install-scripts
btrfs-progs
cryptsetup
dosfstools
gptfdisk
git
github-cli
networkmanager
openssh
rsync
jq
EOF

# The signed repository trust bootstrap.sh runs at first boot needs both
# files already inside the image; fail the build here instead of shipping an
# ISO that only discovers the gap at first boot.
[[ -f "$repo_root/release/repository.env" ]] \
  || { echo 'missing release/repository.env; run the signing-key setup before building the ISO.' >&2; exit 1; }
[[ -f "$repo_root/release/agentos-signing.asc" ]] \
  || { echo 'missing release/agentos-signing.asc; run the signing-key setup before building the ISO.' >&2; exit 1; }

[[ -n "$signed_repo_dir" && -d "$signed_repo_dir" ]] \
  || { echo 'AGENTOS_SIGNED_REPO_DIR must point to the signed AgentOS repository.' >&2; exit 1; }
[[ -f "$signed_repo_dir/agentos.db.tar.gz" ]] \
  || { echo "signed AgentOS repository is missing agentos.db.tar.gz: $signed_repo_dir" >&2; exit 1; }
[[ -f "$signed_repo_dir/release-manifest.json.asc" ]] \
  || { echo 'ISO builds require a signed release manifest; unsigned developer repositories are not accepted.' >&2; exit 1; }

source "$repo_root/release/repository.env"
pacman_config="$work_dir/pacman.conf"
cp /etc/pacman.conf "$pacman_config"
printf '\nCacheDir = %s\n' "$package_cache" >> "$pacman_config"

# The signed AgentOS repository was built and verified by the preceding
# release job. Verify it again from public material before embedding it; the
# ISO builder must never require the private release key.
bash "$repo_root/repository/verify-repo.sh" "$signed_repo_dir" "$repo_root/release/agentos-signing.asc"
jq -e --arg commit "$source_commit" --arg channel "$channel" \
  '.commit == $commit and .channel == $channel' \
  "$signed_repo_dir/release-manifest.json" >/dev/null || {
    echo 'Signed repository must match the selected source commit and installer channel.' >&2; exit 1;
  }

manifest_version="$(jq -er '.version | select(type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$"))' "$signed_repo_dir/release-manifest.json")"
[[ -z "$version" || "$version" == "$manifest_version" ]] || {
  echo 'AGENTOS_VERSION must match the signed repository version.' >&2; exit 1;
}
version="$manifest_version"
printf '%s\n' "$version" > "$source_dir/source/release/installer-version"

# Brand the ISO without maintaining a fragile fork of ArchISO's boot files.
sed -i \
  -e "s/^iso_name=.*/iso_name=\"agentos-${version}\"/" \
  -e 's/^iso_label=.*/iso_label="AGENTOS_$(date +%Y%m)"/' \
  -e 's/^iso_publisher=.*/iso_publisher="AgentOS"/' \
  -e 's/^iso_application=.*/iso_application="AgentOS persistent AI-agent workstation"/' \
  "$profile/profiledef.sh"


# Populate the ISO with the complete Arch dependency closure. The direct
# AgentOS dependencies are listed in packages.txt, so the local install repo
# can be consumed before the target imports the AgentOS signing key.
mapfile -t packages < <(grep -Ev '^[[:space:]]*(#|$)' "$repo_root/packages.txt")
sudo pacman --config "$pacman_config" --cachedir "$package_cache" -Sw --noconfirm \
  "${packages[@]}"

# Turn the exact downloaded closure into a local repository. AgentOS packages
# stay in their separately signed repository; the install repository contains
# only Arch dependencies needed before the AgentOS key is imported in the
# target system.
mkdir -p "$install_repo"
cp -a "$package_cache"/. "$install_repo/"
find "$install_repo" -maxdepth 1 -type f \( \
  -name 'agentos-base-*.pkg.tar.zst*' -o \
  -name 'agentos-runtime-*.pkg.tar.zst*' -o \
  -name 'agentos-shell-*.pkg.tar.zst*' \
\) -delete
repo-add "$install_repo/agentos-install.db.tar.gz" "$install_repo"/*.pkg.tar.zst

# Ship the exact repository revision inside the installer environment.
mkdir -p "$profile/airootfs/root/agentos" "$profile/airootfs/etc"
cp -a "$source_dir/source/." "$profile/airootfs/root/agentos/"
mkdir -p "$profile/airootfs/root/agentos/repository/install/x86_64" "$profile/airootfs/root/agentos/repository/x86_64"
rsync -a "$install_repo/" "$profile/airootfs/root/agentos/repository/install/x86_64/"
rsync -a "$signed_repo_dir/" "$profile/airootfs/root/agentos/repository/x86_64/"

cat > "$profile/airootfs/etc/motd" <<EOF

  AgentOS ${version}
  Channel: ${channel}
  Source: ${source_commit}
  Persistent AI-agent workstation based on Arch Linux.

  Install to disk:
      cd /root/agentos
      ./install.sh

  The base system and signed AgentOS packages are embedded in this ISO.
  Network access is only needed for channel configuration and later updates.

  Existing AgentOS machine:
      sync-workstation

EOF

cat > "$profile/airootfs/root/.zprofile" <<'EOF'
if [[ -t 1 ]]; then
  printf '\nAgentOS installer source: /root/agentos\n'
  printf 'Run: cd /root/agentos && ./install.sh\n\n'
fi
EOF

# Keep checksums beside the ISO for release/disaster-recovery use.
sudo mkarchiso -v -w "$work_dir/mkarchiso" -o "$out_dir" "$profile"
iso="$(find "$out_dir" -maxdepth 1 -type f -name 'agentos-*.iso' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)"
[[ -n "$iso" && -f "$iso" ]] || { echo 'mkarchiso completed but AgentOS ISO was not found.' >&2; exit 1; }
sha256sum "$iso" | tee "$iso.sha256"
printf '\nAgentOS ISO ready:\n  %s\n  %s.sha256\n' "$iso" "$iso"
