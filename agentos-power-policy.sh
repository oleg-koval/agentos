#!/usr/bin/env bash
# Apply the small always-on power policy used by the packaged AgentOS runtime.
set -euo pipefail

[[ ${EUID} -eq 0 ]] || { echo 'Run agentos-power-policy with sudo.' >&2; exit 1; }

case "${1:-apply}" in
  apply)
    install -d -m 755 /etc/systemd/sleep.conf.d
    tmp="$(mktemp /etc/systemd/sleep.conf.d/10-agentos-always-on.conf.XXXXXX)"
    trap 'rm -f "$tmp"' EXIT
    cat > "$tmp" <<'EOF'
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowSuspendThenHibernate=no
AllowHybridSleep=no
EOF
    install -m 644 "$tmp" /etc/systemd/sleep.conf.d/10-agentos-always-on.conf
    rm -f "$tmp"
    trap - EXIT
    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target \
      suspend-then-hibernate.target >/dev/null
    systemctl daemon-reload >/dev/null 2>&1 || true
    ;;
  status)
    [[ -f /etc/systemd/sleep.conf.d/10-agentos-always-on.conf ]] || exit 1
    grep -Fxq 'AllowSuspend=no' /etc/systemd/sleep.conf.d/10-agentos-always-on.conf
    grep -Fxq 'AllowHibernation=no' /etc/systemd/sleep.conf.d/10-agentos-always-on.conf
    ;;
  -h|--help|help)
    printf '%s\n' 'Usage: sudo agentos-power-policy [apply|status]'
    ;;
  *)
    echo 'Usage: sudo agentos-power-policy [apply|status]' >&2
    exit 2
    ;;
esac
