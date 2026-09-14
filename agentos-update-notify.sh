#!/usr/bin/env bash
set -euo pipefail

command -v notify-send >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

state_url="${AGENTOS_UPDATE_STATE_URL:-http://127.0.0.1:4787/v1/state}"
marker="${AGENTOS_UPDATE_NOTIFY_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/agentos/update-notified}"

document="$(curl -fsS --max-time 10 "$state_url" 2>/dev/null)" || exit 0
update="$(jq -cer '.updates | select(type == "object")' <<<"$document" 2>/dev/null)" || exit 0
status="$(jq -r '.status // "not-checked"' <<<"$update")"

case "$status" in
  available)
    title='AgentOS update available'
    target="$(jq -r '.target_version // "new version"' <<<"$update")"
    pending="$(jq -r '.arch_pending // 0' <<<"$update")"
    body="AgentOS $target and $pending Arch package update(s) are ready."
    ;;
  check-failed|apply-failed)
    title='Update needs attention'
    body="$(jq -r '.last_failure // "Open Update Center for details."' <<<"$update")"
    ;;
  reboot-required)
    title='Restart required to finish updating'
    body='Your update completed. Restart when convenient; AgentOS will not restart automatically.'
    ;;
  succeeded)
    title='AgentOS updated successfully'
    body='The guarded update and post-update checks completed.'
    ;;
  *) exit 0 ;;
esac

case "$status" in
  available) revision="$(jq -cr '[.status,.channel,.target_version,.arch_pending] | @json' <<<"$update")" ;;
  check-failed|apply-failed) revision="$(jq -cr '[.status,.channel,.target_version,.last_failure,.snapshot_id,.migration_status] | @json' <<<"$update")" ;;
  reboot-required|succeeded) revision="$(jq -cr '[.status,.channel,.target_version,.last_success_at,.snapshot_id] | @json' <<<"$update")" ;;
esac
if [[ -f "$marker" ]] && grep -Fqx -- "$revision" "$marker"; then
  exit 0
fi

selection="$(notify-send --app-name=AgentOS --icon=system-software-update \
  --action=default='Open Update Center' "$title" "$body")" || exit 0
install -d -m 700 "$(dirname "$marker")"
tmp_marker="$marker.$$"
trap 'rm -f "$tmp_marker"' EXIT
{
  [[ ! -f "$marker" ]] || tail -n 31 "$marker"
  printf '%s\n' "$revision"
} > "$tmp_marker"
chmod 600 "$tmp_marker"
mv "$tmp_marker" "$marker"

if [[ "$selection" == default ]]; then
  curl -fsS --max-time 10 -X POST -H 'Content-Type: application/json' \
    --data '{"name":"update-center-open"}' \
    http://127.0.0.1:4787/v1/action >/dev/null 2>&1 || true
fi
