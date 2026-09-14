#!/usr/bin/env bash
set -euo pipefail

root="${AGENTOS_MIGRATION_ROOT:-}"
rm -f -- "$root/usr/share/wallpapers/AgentOS/wallpaper.svg"
