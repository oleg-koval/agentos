#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

pkgver="$(sed -nE "s/^pkgver='?([^']+)'?$/\1/p" packages/agentos-runtime/PKGBUILD)"
pkgrel="$(sed -nE "s/^pkgrel='?([^']+)'?$/\1/p" packages/agentos-runtime/PKGBUILD)"
[[ "$pkgver" && "$pkgrel" ]] || { echo 'runtime PKGBUILD version is incomplete' >&2; exit 1; }
current="${pkgver}-${pkgrel}"
shell_pkgver="$(sed -nE "s/^pkgver='?([^']+)'?$/\1/p" packages/agentos-shell/PKGBUILD)"
shell_pkgrel="$(sed -nE "s/^pkgrel='?([^']+)'?$/\1/p" packages/agentos-shell/PKGBUILD)"
[[ "$shell_pkgver" && "$shell_pkgrel" ]] || { echo 'shell PKGBUILD version is incomplete' >&2; exit 1; }
shell_current="${shell_pkgver}-${shell_pkgrel}"

manifest="${AGENTOS_LIVE_RELEASE_MANIFEST:-}"
tmp=''
if [[ -z "$manifest" ]]; then
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  # The published manifest is the authoritative stable version. This check is
  # overridable with a fixture path for offline/reproducible CI tests.
  base_url="${AGENTOS_VERSION_BASE_URL:-$(sed -nE 's/^AGENTOS_REPO_BASE_URL=(.*)$/\1/p' release/repository.env)}"
  curl -fsSL --max-time 20 "${base_url%/}/stable/release-manifest.json" -o "$tmp"
  manifest="$tmp"
fi
live_name="$(jq -er '.packages[] | select(.name | startswith("agentos-runtime-")) | select(.name | contains("-debug-") | not) | .name' "$manifest" | head -1)"
live="${live_name#agentos-runtime-}"
live="${live%-x86_64.pkg.tar.zst}"
[[ "$live" != "$live_name" && "$live" != '' ]] || { echo 'stable manifest has no runtime package' >&2; exit 1; }
shell_live_name="$(jq -er '.packages[] | select(.name | startswith("agentos-shell-")) | .name' "$manifest" | head -1)"
shell_live="${shell_live_name#agentos-shell-}"
shell_live="${shell_live%-x86_64.pkg.tar.zst}"
[[ "$shell_live" != "$shell_live_name" && "$shell_live" != '' ]] || { echo 'stable manifest has no shell package' >&2; exit 1; }

# Every shipped runtime input in a PR must carry a pkgver/pkgrel change. This
# prevents pacman from retaining an older archive after a source-only fix.
base_ref="${AGENTOS_VERSION_BASE_REF:-origin/main}"
git rev-parse --verify "${base_ref}^{commit}" >/dev/null 2>&1 || {
  echo "package-version comparison base is unavailable: $base_ref" >&2
  exit 1
}
runtime_changed=0
while IFS= read -r path; do
  case "$path" in
    core/*|packages/agentos-runtime/*|systemd/*|pacman-hooks/*|registry/*|migrations/*|.agents/*|AGENTS.md|\
    agentos-cli.sh|install-agent-tools.sh|agentos-agent-event.sh|agentos-native-event.sh|\
    agentos-herdr-bridge.sh|agentos-transaction.sh|agentos-boot-health.sh|agentos-repository.sh|\
    agentos-onboarding.sh|agentos-vps-install.sh|agentos-power-policy.sh|agentos-weekly-update.sh|agentos-migrate-notify.sh|agentos-update-notify.sh|\
    workstation-doctor.sh|maintenance-check.sh|rollback-boot-cleanup.sh|hermes-backup.sh|\
    restic-verify.sh|agentos-support.sh|agentos-telemetry.sh|setup-project-layout.sh|\
    ensure-repository-config.sh|ensure-agentos-config.sh|repository/verify-repo.sh|\
    rollback-workstation.sh|btrfs-pre-pacman-snapshot.sh|btrfs-prune-snapshots.sh|\
    docs/help.md|docs/troubleshooting.md|docs/friend-system-acceptance.md|docs/vps-onboarding.md|docs/vps-providers.md|\
    config/agentos-config.example.yaml|agentos-hermes-plugin/*|release/channels/*|release/tool-versions.json)
      runtime_changed=1
      ;;
  esac
done < <(git diff --name-only "$base_ref"...HEAD)
shell_changed=0
while IFS= read -r path; do
  case "$path" in
    packages/agentos-shell/*|agentos-home.sh|agentos-ui.sh|agentos-shell.sh|agentos-desktop.sh|\
    agentos-native-workspace.sh|agentos/native-shell/*|agentos/desktop/*|agentos/theme/*|agentos/kwin/*|\
    systemd/user/agentos-home.service|systemd/user/agentos-native-workspace.service|systemd/user/agentos-ui@.service)
      shell_changed=1
      ;;
  esac
done < <(git diff --name-only "$base_ref"...HEAD)
if (( runtime_changed )); then
  git diff --unified=0 "$base_ref"...HEAD -- packages/agentos-runtime/PKGBUILD \
    | grep -Eq '^[+]pkg(ver|rel)=' || {
    echo 'runtime inputs changed without advancing packages/agentos-runtime/pkgver or pkgrel' >&2
    exit 1
  }
fi

compare_versions() {
  if command -v vercmp >/dev/null 2>&1; then
    vercmp "$1" "$2"
  else
    python3 - "$1" "$2" <<'PY'
import re
import sys

def parts(value: str) -> tuple[tuple[int, object], ...]:
    return tuple(
        (0, int(part)) if part.isdigit() else (1, part)
        for part in re.findall(r"[0-9]+|[A-Za-z]+", value)
    )

current, live = parts(sys.argv[1]), parts(sys.argv[2])
print((current > live) - (current < live))
PY
  fi
}

comparison="$(compare_versions "$current" "$live")"

if (( runtime_changed )); then
  relation='>'
  (( comparison > 0 )) || {
    echo "runtime package $current is not newer than stable $live" >&2
    exit 1
  }
else
  relation='>='
  (( comparison >= 0 )) || {
    echo "runtime package $current is older than stable $live" >&2
    exit 1
  }
fi

echo "Runtime package version contract passed: $current $relation stable $live."

if (( shell_changed )); then
  git diff --unified=0 "$base_ref"...HEAD -- packages/agentos-shell/PKGBUILD \
    | grep -Eq '^[+]pkg(ver|rel)=' || {
    echo 'shell inputs changed without advancing packages/agentos-shell/pkgver or pkgrel' >&2
    exit 1
  }
fi
shell_comparison="$(compare_versions "$shell_current" "$shell_live")"
if (( shell_changed )); then
  shell_relation='>'
  (( shell_comparison > 0 )) || {
    echo "shell package $shell_current is not newer than stable $shell_live" >&2
    exit 1
  }
else
  shell_relation='>='
  (( shell_comparison >= 0 )) || {
    echo "shell package $shell_current is older than stable $shell_live" >&2
    exit 1
  }
fi
echo "Shell package version contract passed: $shell_current $shell_relation stable $shell_live."
