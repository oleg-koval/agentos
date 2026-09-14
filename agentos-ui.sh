#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-palette}"
case "$cmd" in
  palette|workspace|agents|activity|system) ;;
  *) echo 'Usage: agentos-ui {palette|workspace|agents|activity|system}' >&2; exit 2 ;;
esac

state_dir="$HOME/.local/share/agentos-home"
mkdir -p "$state_dir"
printf '%s\n' "$cmd" > "$state_dir/ui-command"

# Bring the existing Home surface forward. Do not start a second Chromium app.
if command -v qdbus6 >/dev/null 2>&1; then
  qdbus6 org.kde.KWin /KWin org.kde.KWin.showDesktop false >/dev/null 2>&1 || true
fi

# If Home is not running, ask systemd to restore it. The command file is kept
# and will be consumed as soon as the shell starts.
systemctl --user is-active agentos-home.service >/dev/null 2>&1 || systemctl --user start agentos-home.service >/dev/null 2>&1 || true
