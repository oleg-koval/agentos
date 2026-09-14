#!/usr/bin/env bash
set -euo pipefail

: "${HOME:?HOME is required for the user migration}"
rm -f -- \
  "$HOME/.config/systemd/user/agentos-home.service" \
  "$HOME/.config/systemd/user/agentos-ui@.service"
rm -rf -- "$HOME/.local/share/kwin/scripts/agentos-shell"
