#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

scripts=(agentos-repository.sh build-agentos-iso.sh install.sh bootstrap.sh repository/create-signing-key.sh repository/build-repo.sh repository/verify-repo.sh release/build-manifest.sh release/promote-repository.sh release/pages-overlay.sh release/fetch-live-channel.sh release/query-tool-versions.sh tests/release-manifest.sh tests/release-promotion.sh tests/repository-verify.sh tests/repository-trust.sh tests/package-version.sh tests/boot-health.sh tests/package-content.sh tests/package-install-migration.sh tests/migration.sh tests/install-completeness.sh tests/package-collision.sh tests/tool-versions.sh)
for s in "${scripts[@]}"; do
  [[ -f "$s" ]] || { echo "missing release script: $s" >&2; exit 1; }
  bash -n "$s"
done
if command -v shellcheck >/dev/null 2>&1; then shellcheck -S error "${scripts[@]}"; fi

[[ -f .github/workflows/release.yml ]]
! grep -Fq 'schedule:' .github/workflows/release.yml
! grep -Fq "cron: '0 5 * * 0'" .github/workflows/release.yml
grep -Fq 'branches: [main]' .github/workflows/release.yml
grep -Fq 'TARGET_CHANNEL: ${{ inputs.channel }}' .github/workflows/release.yml
grep -Fq 'AGENTOS_GPG_PRIVATE_KEY' .github/workflows/release.yml
grep -Fq 'AGENTOS_GPG_KEY_ID' .github/workflows/release.yml
grep -Fq 'gpg --batch --verify' .github/workflows/release.yml
grep -Fq 'actions/download-artifact@v4' .github/workflows/release.yml
grep -Fq 'actions/upload-pages-artifact' .github/workflows/release.yml
grep -Fq 'actions/deploy-pages' .github/workflows/release.yml
grep -Fq 'Deploy promoted signed channel repository' .github/workflows/release.yml
grep -Fq 'Publish standalone VPS bootstrap asset' .github/workflows/release.yml
grep -Fq 'agentos-vps-install.sh.sha256' .github/workflows/release.yml
grep -Fq 'sha256sum "$GITHUB_WORKSPACE/agentos-vps-install.sh"' .github/workflows/release.yml
grep -Fq 'cp source/agentos-vps-install.sh source/agentos-vps-install.sh.sha256 out/repo/' .github/workflows/release.yml
grep -Fq "if: \${{ needs.promote.result == 'success' }}" .github/workflows/release.yml
grep -Fq "inputs.channel != 'edge'" .github/workflows/release.yml
! grep -Fq "needs.promote.outputs.target_channel == 'stable'" .github/workflows/release.yml
grep -Fq 'release/fetch-live-channel.sh' .github/workflows/release.yml
grep -Fq 'release/pages-overlay.sh' .github/workflows/release.yml
grep -Fq 'out/site' .github/workflows/release.yml
grep -Fq 'install.html' release/assemble-site-root.sh
grep -Fq 'support.html' release/assemble-site-root.sh
grep -Fq 'build_iso' .github/workflows/release.yml
grep -Fq 'needs: [verify, promote]' .github/workflows/release.yml
grep -Fq 'Download the verified signed AgentOS repository' .github/workflows/release.yml
grep -Fq 'AGENTOS_SIGNED_REPO_DIR=/workspace/iso-repo/x86_64' .github/workflows/release.yml
grep -Fq 'AGENTOS_VERSION="$VERSION"' .github/workflows/release.yml
grep -Fq 'agentos-*.iso' .github/workflows/release.yml
grep -Fq -- '--batch --yes --armor --detach-sign' .github/workflows/release.yml
grep -Fq 'sha256sum "$(basename "$iso")" > "$(basename "$iso").sha256"' .github/workflows/release.yml
grep -Fq '.commit == $commit' .github/workflows/release.yml
grep -Fq '"agentos-${version}-"*.iso) ;;' .github/workflows/release.yml
python3 tests/iso-artifact.py
python3 tests/installer-version.py
grep -Fq 'cp out/repo/x86_64/agentos.db "$flat/"' .github/workflows/release.yml
grep -Fq 'cp out/repo/x86_64/agentos.db.sig "$flat/"' .github/workflows/release.yml
grep -Fq 'cp out/repo/x86_64/agentos.files "$flat/"' .github/workflows/release.yml
grep -Fq 'cp out/repo/x86_64/agentos.files.sig "$flat/"' .github/workflows/release.yml

grep -Fq 'SigLevel = Required' core/cmd/agentos-ops/main.go
grep -Fq 'pacman-key", "--lsign-key' core/cmd/agentos-ops/main.go
grep -Fq 'fingerprint mismatch' core/cmd/agentos-ops/main.go
grep -Fq 'repository URL must use HTTPS' core/cmd/agentos-ops/main.go

grep -Fq 'gpg --batch --yes --detach-sign' repository/build-repo.sh
grep -Fq 'agentos.db.sig' repository/build-repo.sh
grep -Fq 'agentos.release/v2' release/build-manifest.sh
grep -Fq 'AGENTOS_BUILD_COMMIT' release/build-manifest.sh
grep -Fq 'AGENTOS_BOOTSTRAP' release/build-manifest.sh
grep -Fq '.bootstrap.sha256' release/promote-repository.sh
grep -Fq 'release-manifest.json.asc' .github/workflows/release.yml
grep -Fq 'promote-repository.sh' .github/workflows/release.yml
grep -Fq 'agentos-edge-repository' .github/workflows/release.yml
grep -Fq 'agentos-beta-repository' .github/workflows/release.yml
grep -Fq 'source_run_id' .github/workflows/release.yml
grep -Fq 'GITHUB_STEP_SUMMARY' .github/workflows/release.yml
grep -Fq "run.path !== '.github/workflows/release.yml'" .github/workflows/release.yml
grep -Fq 'overwrite: true' .github/workflows/release.yml
# The site root must track stable, not whichever channel published last.
grep -Fq 'assemble-site-root.sh "$TARGET_CHANNEL"' .github/workflows/release.yml
! grep -Fq 'cp out/repo/agentos-vps-install.sh out/site/' .github/workflows/release.yml
bash tests/fetch-live-root.sh >/dev/null
python3 tests/site.py
bash tests/assemble-site-root.sh >/dev/null

# Beta is a published candidate, stable is the friend default, and edge stays
# artifact-only. Keep operator docs aligned with the actual promotion workflow.
grep -Fq 'This publishes `/beta`' docs/release-promotion.md
grep -Fq 'Edge is an Actions artifact' docs/release-promotion.md
grep -Fq 'Automatic stable promotion is disabled' docs/release-promotion.md
grep -Fq 'beta publishes `/beta`' docs/releasing.md
grep -Fq 'A beta build dispatch also publishes the beta package channel' docs/releasing.md
! grep -Fq 'Beta and edge remain workflow artifacts' docs/release-promotion.md

grep -Fq 'mode == "--scheduled"' core/cmd/agentos-ops/main.go
grep -Fq 'channel != "stable"' core/cmd/agentos-ops/main.go
grep -Fq 'repository configure' core/cmd/agentos-ops/main.go

grep -Fq 'agentos-repository' packages/agentos-runtime/PKGBUILD
grep -Fq './cmd/agentosd2' packages/agentos-runtime/PKGBUILD
grep -Fq 'agentos.repository/v1' core/cmd/agentos-ops/main.go
grep -Fq 'AGENTOS_PACMAN_INCLUDE' core/cmd/agentos-ops/main.go
grep -Fq 'Include = ' core/cmd/agentos-ops/main.go
grep -Fq 'repositoryConfigPresent' core/cmd/agentos-ops/main.go
grep -Fq 'pacmanConf' core/cmd/agentos-ops/main.go
grep -Fq 'agentos-repository migrate' packages/agentos-runtime/agentos-runtime.install
grep -Fq 'systemctl --global enable agentosd.service agentos-herdr-bridge.service' packages/agentos-runtime/agentos-runtime.install
grep -Fq 'Environment=PATH=%h/.local/bin:/usr/bin' systemd/user/agentos-herdr-bridge.service
grep -Fq 'ExecStart=/usr/bin/agentos-boot-health check' systemd/system/agentos-boot-health.service
grep -Fq 'ExecStart=/usr/lib/agentos/agentos-weekly-update --scheduled' systemd/system/agentos-weekly-update.service
grep -Fq '/usr/share/agentos/wallpaper.svg' packages/agentos-shell/PKGBUILD
grep -Fq 'post_install' packages/agentos-shell/agentos-shell.install
grep -Fq '.local/share/kwin/scripts/agentos-shell' migrations/user/20260906-001-remove-legacy-shell-overrides.sh
grep -Fq 'AGENTOS_KWIN_SOURCE' packages/agentos-shell/agentos-shell.install
grep -Fq 'runuser -u "$user"' packages/agentos-shell/agentos-shell.install
grep -Fq 'pre_upgrade()' packages/agentos-shell/agentos-shell.install
grep -Fq 'parent/agentos-shell' packages/agentos-shell/agentos-shell.install
grep -Fq 'StopUnit' agentos/kwin/contents/code/main.js
grep -Fq 'agentos-home.service' packages/agentos-shell/PKGBUILD
grep -Fq 'ExecStart=/usr/bin/agentos-home' systemd/user/agentos-home.service
grep -Fq 'ExecStart=/usr/bin/agentos-ui %i' systemd/user/agentos-ui@.service
grep -Fq 'ExecStart=/usr/bin/agentos-native-workspace' systemd/user/agentos-native-workspace.service
grep -Fq 'WantedBy=graphical-session.target' systemd/user/agentos-native-workspace.service
grep -Fq 'agentos-home.service agentos-native-workspace.service' packages/agentos-shell/agentos-shell.install
awk '/^pkgrel=/{if ($0 ~ /^pkgrel=[0-9]+$/ && substr($0,8) + 0 >= 36) found=1} END{exit !found}' packages/agentos-runtime/PKGBUILD

grep -Fq 'quick-generate-key' repository/create-signing-key.sh
grep -Fq 'ed25519 cert never' repository/create-signing-key.sh
grep -Fq 'quick-add-key' repository/create-signing-key.sh
grep -Fq 'ed25519 sign "$SUBKEY_EXPIRE"' repository/create-signing-key.sh
! grep -Fq 'Key-Usage: sign' repository/create-signing-key.sh

! grep -Fq '@latest' update-workstation.sh
! grep -Fq '@latest' install-agent-tools.sh

grep -Fq 'verify:' .github/workflows/release.yml
grep -Fq 'needs: build-edge' .github/workflows/release.yml
grep -Fq 'repository/verify-repo.sh artifact/x86_64 release/agentos-signing.asc' .github/workflows/release.yml
grep -Fq 'AGENTOS_VERIFY_MIN_DAYS' .github/workflows/release.yml

bash tests/release-promotion.sh
bash tests/repository-trust.sh

grep -Fq "step 'Signed repository'" bootstrap.sh
grep -Fq 'agentos-repository.sh configure' bootstrap.sh
grep -Fq 'pacman -Sy --noconfirm agentos-base agentos-runtime agentos-shell' bootstrap.sh

grep -Fq "missing release/repository.env" build-agentos-iso.sh
grep -Fq "missing release/agentos-signing.asc" build-agentos-iso.sh
grep -Fq 'AGENTOS_SIGNED_REPO_DIR' build-agentos-iso.sh
grep -Fq 'pacman --config "$pacman_config" --cachedir "$package_cache" -Sw' build-agentos-iso.sh
grep -Fq 'repository/verify-repo.sh' build-agentos-iso.sh
grep -Fq 'repo-add "$install_repo/agentos-install.db.tar.gz"' build-agentos-iso.sh
grep -Fq 'The base system and signed AgentOS packages are embedded' build-agentos-iso.sh
grep -Fq 'release/export-source.sh' build-agentos-iso.sh
bash tests/export-source.sh
python3 tests/publication-outage.py
grep -Fq 'AGENTOS_PACKAGE_CACHE' install.sh
grep -Fq 'AGENTOS_INSTALL_REPO' install.sh
grep -Fq 'SigLevel = Required DatabaseNever' install.sh
grep -Fq 'pacstrap -c -K -C' install.sh
grep -Fq 'AGENTOS_LOCAL_REPO' bootstrap.sh
grep -Fq 'pacman -U --noconfirm' bootstrap.sh

grep -Fq 'Unsupported channel:' bootstrap.sh

echo 'Release/distribution static validation passed.'
