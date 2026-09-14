#!/usr/bin/env bash
# Create a local, redacted support bundle without uploading anything.
set -euo pipefail

output=''
include_logs=0

usage() {
  cat <<'EOF'
Usage: agentos-support [bundle] [--output PATH] [--include-logs]

Creates a redacted Markdown report locally. Logs are excluded by default;
--include-logs adds bounded warning/error journal counts by priority.
Nothing is uploaded automatically.
EOF
}

while (($# > 0)); do
  case "$1" in
    bundle) ;;
    --output) (($# >= 2)) || { echo '--output needs a path.' >&2; exit 2; }; output="$2"; shift ;;
    --include-logs) include_logs=1 ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ -z "$output" ]]; then
  output="${AGENTOS_SUPPORT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agentos}/support-$(date -u +%Y%m%dT%H%M%SZ).md"
fi
output_dir="$(dirname "$output")"
if [[ -e "$output_dir" ]]; then
  [[ -d "$output_dir" ]] || { echo "Support output parent is not a directory: $output_dir" >&2; exit 1; }
else
  (umask 077; mkdir -p -- "$output_dir")
fi

if [[ -e "$output" || -L "$output" ]]; then
  echo "Refusing to overwrite existing support output: $output" >&2
  exit 1
fi
umask 077
if ! { set -o noclobber; exec 3> "$output"; } 2>/dev/null; then
  echo "Refusing to overwrite existing support output: $output" >&2
  exit 1
fi

redact() {
  awk '
    /-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----/ {
      private_key = 1
      print "<private key block redacted>"
      next
    }
    private_key {
      if ($0 ~ /-----END [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----/) private_key = 0
      next
    }
    { print }
  ' | sed -E \
    -e 's#(/home/[^[:space:]/]+|/Users/[^[:space:]/]+)#<home>#g' \
    -e 's#([Bb]earer[[:space:]]+)[^[:space:]]+#\1<redacted>#g' \
    -e 's#([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn][[:space:]"]*[:=][[:space:]"]*).*#\1<redacted>#' \
    -e 's#(([Ss][Ee][Tt]-)?[Cc][Oo][Oo][Kk][Ii][Ee][[:space:]"]*[:=][[:space:]"]*).*#\1<redacted>#' \
    -e 's#([Xx]-[Aa][Pp][Ii]-[Kk][Ee][Yy]|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Pp]assword|[Pp]asswd|[Tt]oken|[Ss]ecret|[Pp]rivate[_-]?[Kk]ey|[Cc]redential)([[:space:]"]*[=:][[:space:]"]*).*#\1\2<redacted>#' \
    -e 's#^(Host:|Hostname:)[[:space:]].*#\1 <redacted>#I' \
    -e 's#([0-9]{1,3}\.){3}[0-9]{1,3}#<ip>#g'
}

bounded_output() {
  awk '
    BEGIN { max_lines = 80; max_chars = 16384 }
    {
      if (NR > max_lines || chars >= max_chars) {
        truncated = 1
        next
      }
      remaining = max_chars - chars
      if (length($0) + 1 > remaining) {
        print substr($0, 1, remaining)
        chars = max_chars
        truncated = 1
        next
      }
      print
      chars += length($0) + 1
    }
    END { if (truncated) print "[output truncated]" }
  '
}

section() {
  local title="$1"; shift
  printf '\n## %s\n\n```\n' "$title" >&3
  local text status
  if text="$("$@" 2>&1 | bounded_output)"; then
    status=0
  else
    status=$?
  fi
  printf '%s\n' "$text" | redact >&3
  printf 'exit status: %s\n```\n' "$status" >&3
}

journal_priority_aggregate() {
  local aggregate status
  if aggregate="$(journalctl -b -p warning..alert -n 100 --no-pager --quiet --output=json --output-fields=PRIORITY 2>/dev/null | awk '
    {
      if (match($0, /"PRIORITY"[[:space:]]*:[[:space:]]*"?[0-4]"?/)) {
        priority = substr($0, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", priority)
        counts[priority]++
      }
    }
    END {
      print "Window: latest 100 warning-or-higher entries"
      printf "Emergency: %d\n", counts[0]
      printf "Alert: %d\n", counts[1]
      printf "Critical: %d\n", counts[2]
      printf "Error: %d\n", counts[3]
      printf "Warning: %d\n", counts[4]
    }
  ')"; then
    printf '%s\n' "$aggregate"
    return 0
  else
    status=$?
  fi
  echo 'Journal priority aggregate unavailable.' >&2
  return "$status"
}

cat >&3 <<EOF
# AgentOS support report

- Schema: agentos.support/v1
- Created: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Logs included: $([[ "$include_logs" == 1 ]] && echo yes || echo no)

This report is generated locally. Review it before sharing. It must not contain
passwords, private keys, tokens, prompts, document contents, or unrelated
personal data.
EOF

section 'Version' agentos version
section 'Workstation doctor' workstation-doctor --check
section 'Repository' agentos repository status
section 'Failed system units' systemctl --failed --no-legend
section 'Failed user units' systemctl --user --failed --no-legend
if [[ "$include_logs" == 1 ]]; then
  section 'Recent journal priority aggregate' journal_priority_aggregate
fi

exec 3>&-
printf 'Support report created: %s\n' "$output"
