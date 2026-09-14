#!/usr/bin/env bash
# Send actionable workstation failures through Hermes' configured messaging target.
set -uo pipefail

CONFIG_FILE="${AGENTOS_HOST_CONFIG:-${LEGACY_WORKSTATION_CONFIG:-/etc/agentos/host.conf}}"
if [[ ! -r "$CONFIG_FILE" && -r /etc/legacy-workstation.conf ]]; then CONFIG_FILE=/etc/legacy-workstation.conf; fi
STATE_DIR="${WORKSTATION_ALERT_STATE_DIR:-/var/lib/agentos/alerts}"
SUBJECT='AgentOS alert'
FILE=''

if [[ -r "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

WORKSTATION_USER="${WORKSTATION_USER:-${SUDO_USER:-$(id -un)}}"
USER_HOME="$(getent passwd "$WORKSTATION_USER" 2>/dev/null | cut -d: -f6)"
USER_UID="$(id -u "$WORKSTATION_USER" 2>/dev/null || true)"
USER_HOME="${USER_HOME:-$HOME}"

usage() {
  echo 'Usage: workstation-alert [--subject TEXT] [--file PATH] [MESSAGE]' >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      SUBJECT="$2"
      shift 2
      ;;
    --file)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      FILE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

if [[ -n "$FILE" ]]; then
  [[ -r "$FILE" ]] || { echo "Alert file is not readable: $FILE" >&2; exit 2; }
  MESSAGE="$(cat "$FILE")"
elif [[ $# -gt 0 ]]; then
  MESSAGE="$*"
elif [[ ! -t 0 ]]; then
  MESSAGE="$(cat)"
else
  usage
  exit 2
fi

[[ -n "${MESSAGE//[[:space:]]/}" ]] || exit 0

TARGET="${WORKSTATION_ALERT_TARGET:-telegram}"
target_file="$USER_HOME/.config/agentos/alert-target"
if [[ ! -r "$target_file" && -r "$USER_HOME/.config/legacy-workstation/alert-target" ]]; then
  target_file="$USER_HOME/.config/legacy-workstation/alert-target"
fi
if [[ -r "$target_file" ]]; then
  TARGET="$(head -n1 "$target_file" | tr -d '\r\n')"
fi
[[ -n "$TARGET" ]] || TARGET=telegram

# Keep Telegram-sized alerts compact. The full report remains on disk/journal.
if (( ${#MESSAGE} > 3500 )); then
  MESSAGE="${MESSAGE:0:3500}"$'\n\n[truncated; run workstation-doctor for the full report]'
fi

if [[ ! -d "$USER_HOME/.hermes" ]]; then
  logger -t workstation-alert 'Hermes is not configured; alert not sent.' 2>/dev/null || true
  exit 0
fi

send_alert() {
  env HOME="$USER_HOME" XDG_RUNTIME_DIR="/run/user/$USER_UID" \
    PATH="$USER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    hermes send --to "$TARGET" --subject "$SUBJECT" --quiet "$MESSAGE"
}

# Avoid repeating the same underlying health failure more than once per day.
# Doctor reports contain a generation timestamp, so strip volatile report lines
# before hashing while keeping the actual delivered message unchanged.
if [[ ${EUID} -eq 0 ]]; then
  install -d -m 755 "$STATE_DIR"
  normalized="$(printf '%s\n' "$MESSAGE" | sed -E '/^(Generated:|Saved report:)/d')"
  digest="$(printf '%s\0%s' "$SUBJECT" "$normalized" | sha256sum | awk '{print $1}')"
  state="$STATE_DIR/last-alert"
  if [[ -r "$state" ]]; then
    old_digest=''
    old_time=0
    read -r old_digest old_time < "$state" || true
    now="$(date +%s)"
    if [[ "$old_digest" == "$digest" && "$old_time" =~ ^[0-9]+$ && $((now - old_time)) -lt 86400 ]]; then
      exit 0
    fi
  fi
fi

if [[ $(id -un) == "$WORKSTATION_USER" && ${EUID} -ne 0 ]]; then
  send_alert
  status=$?
elif [[ ${EUID} -eq 0 && -n "$USER_UID" ]]; then
  runuser -u "$WORKSTATION_USER" -- env HOME="$USER_HOME" XDG_RUNTIME_DIR="/run/user/$USER_UID" \
    PATH="$USER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    hermes send --to "$TARGET" --subject "$SUBJECT" --quiet "$MESSAGE"
  status=$?
else
  status=1
fi

if (( status != 0 )); then
  logger -t workstation-alert "Hermes alert delivery failed for target $TARGET" 2>/dev/null || true
  exit 0
fi

if [[ ${EUID} -eq 0 ]]; then
  printf '%s %s\n' "$digest" "$(date +%s)" > "$state"
  chmod 600 "$state"
fi
