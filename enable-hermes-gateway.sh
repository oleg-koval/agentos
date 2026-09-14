#!/usr/bin/env bash
# Install and start Hermes as an always-on systemd user service.
set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

if [[ ${EUID} -eq 0 ]]; then
  echo 'Run enable-hermes-gateway as the workstation user, not root.' >&2
  exit 1
fi

command -v hermes >/dev/null 2>&1 || { echo 'Hermes is not installed.' >&2; exit 1; }

# If Herdr is installed, wire Hermes lifecycle/session reporting before the
# gateway starts so the plugin is loaded immediately.
if command -v herdr >/dev/null 2>&1 && [[ -d "$HOME/.hermes" ]]; then
  echo 'Installing/updating Herdr Hermes integration.'
  herdr integration install hermes
fi

# Linger is also converged by sync-workstation, but enforce it here so this
# helper is safe to use independently.
sudo install -d -m 755 /var/lib/systemd/linger
sudo touch "/var/lib/systemd/linger/$USER"

hermes gateway install
systemctl --user daemon-reload
systemctl --user enable hermes-gateway.service >/dev/null 2>&1 || true
hermes gateway start

echo
printf 'Linger: %s\n' "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo unknown)"
hermes gateway status
