#!/usr/bin/env bash
set -euo pipefail

command -v notify-send >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
agentos_bin="${AGENTOS_NOTIFY_AGENTOS_BIN:-/usr/bin/agentos}"
[[ -x "$agentos_bin" ]] || exit 0

report="$("$agentos_bin" migrate status --scope user --json 2>/dev/null)" || exit 0
pending="$(jq -er '[.scopes[] | select(.scope == "user") | .migrations[] | select(.status == "pending")] | length' <<<"$report")" || exit 0
failed="$(jq -er '[.scopes[] | select(.scope == "user") | .migrations[] | select(.status == "failed")] | length' <<<"$report")" || exit 0
(( pending > 0 || failed > 0 )) || exit 0

summary='AgentOS setup update'
body="$pending change(s) ready to apply."
urgency='normal'
if (( failed > 0 )); then
  body="$failed setup migration(s) need review and retry."
  urgency='critical'
fi

action="$(notify-send --app-name=AgentOS --urgency="$urgency" \
  --action=default='Review and apply' --wait "$summary" "$body" 2>/dev/null || true)"
[[ "$action" == default ]] || exit 0

systemd-run --user --quiet --collect --property=Type=exec \
  --unit="agentos-migrate-$(date +%s%N)" \
  kitty -e zsh -lc "agentos migrate apply --scope user; echo; read -k1 '?Press any key to close'"
