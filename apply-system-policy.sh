#!/usr/bin/env bash
# Install the non-package host state shared by fresh install and sync.
# Everything else (binaries, shell entrypoints, systemd units, pacman hooks,
# the sleep policy, and the /usr/share/agentos payload) is owned by the
# agentos-base/agentos-runtime/agentos-shell pacman packages.
set -euo pipefail

SOURCE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
WORKSTATION_USER="${WORKSTATION_USER:-${SUDO_USER:-}}"
AGENTOS_REPO="${AGENTOS_REPO:-}"

if [[ ${EUID} -ne 0 ]]; then echo 'Run apply-system-policy as root.' >&2; exit 1; fi
[[ "$WORKSTATION_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ && "$WORKSTATION_USER" != root ]] || {
  echo 'WORKSTATION_USER must be a non-root Linux login name.' >&2
  exit 2
}
[[ -f "$SOURCE_DIR/ensure-agentos-config.sh" ]] || { echo "Missing policy file: $SOURCE_DIR/ensure-agentos-config.sh" >&2; exit 1; }

install -d -m 755 /etc/agentos

[[ -f /etc/agentos/channel ]] || echo stable > /etc/agentos/channel
channel="${AGENTOS_CHANNEL:-$(cat /etc/agentos/channel)}"
case "$channel" in stable|beta|edge|none) ;; *) echo "Unsupported channel: $channel" >&2; exit 2 ;; esac
if [[ -f "$SOURCE_DIR/release/installer-version" ]]; then
  cat "$SOURCE_DIR/release/installer-version" > /etc/agentos/version
elif [[ -f "$SOURCE_DIR/release/channels/$channel.json" ]] && command -v jq >/dev/null 2>&1; then
  jq -er '.version' "$SOURCE_DIR/release/channels/$channel.json" > /etc/agentos/version
else
  echo dev > /etc/agentos/version
fi
chmod 644 /etc/agentos/channel /etc/agentos/version

if [[ -z "$AGENTOS_REPO" && -d "$SOURCE_DIR/.git" ]]; then
  AGENTOS_REPO="$(git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null || true)"
fi
if [[ -n "$AGENTOS_REPO" ]]; then
  if [[ "$AGENTOS_REPO" == *$'\r'* || "$AGENTOS_REPO" == *$'\n'* ]]; then
    echo 'AGENTOS_REPO must not contain carriage returns or newlines.' >&2
    exit 2
  fi
  if [[ "$AGENTOS_REPO" =~ ^[Hh][Tt][Tt][Pp][Ss]?://[^/]*@ ]]; then
    echo 'AGENTOS_REPO HTTP(S) URLs must not contain userinfo.' >&2
    exit 2
  fi
  printf '%s\n' "$AGENTOS_REPO" > /etc/agentos/repository-url
  chmod 644 /etc/agentos/repository-url
fi

cat > /etc/agentos/host.conf <<EOF
WORKSTATION_USER=$(printf '%q' "$WORKSTATION_USER")
EOF
chmod 644 /etc/agentos/host.conf
if [[ ! -e /etc/legacy-workstation.conf ]]; then
  ln -s /etc/agentos/host.conf /etc/legacy-workstation.conf
fi
user_home="$(getent passwd "$WORKSTATION_USER" | cut -d: -f6)"
if [[ -n "$user_home" && -d "$user_home" ]]; then
  install -d -o "$WORKSTATION_USER" -g "$WORKSTATION_USER" -m 700 "$user_home/.config/agentos"
  if [[ ! -e "$user_home/.config/legacy-workstation" ]]; then
    ln -s "$user_home/.config/agentos" "$user_home/.config/legacy-workstation"
  fi
fi

AGENTOS_WORKSTATION_USER="$WORKSTATION_USER" \
  AGENTOS_CONFIG_FILE=/etc/agentos/config.yaml \
  "$SOURCE_DIR/ensure-agentos-config.sh"

# Legacy host cleanup: no package ships an update-workstation.timer/.service,
# so nothing else ever removes a copy left by a pre-package install.
systemctl disable update-workstation.timer >/dev/null 2>&1 || true
systemctl stop update-workstation.timer update-workstation.service >/dev/null 2>&1 || true
systemctl reset-failed update-workstation.timer update-workstation.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/update-workstation.timer /etc/systemd/system/update-workstation.service
systemctl daemon-reload >/dev/null 2>&1 || true

# Lingering is per-user host state; no package sets it.
install -d -m 755 /var/lib/systemd/linger
touch "/var/lib/systemd/linger/$WORKSTATION_USER"
chmod 644 "/var/lib/systemd/linger/$WORKSTATION_USER"

printf 'Host state written for user %s: channel, version, repository URL, host.conf and per-user config are in place. AgentOS runtime, shell and reliability services are managed by the agentos-base/agentos-runtime/agentos-shell packages.\n' "$WORKSTATION_USER"
