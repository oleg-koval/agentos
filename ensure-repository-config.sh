#!/usr/bin/env bash
set -euo pipefail

# Pacman transactions can replace administrator configuration indirectly. If
# AgentOS was already trusted/configured, restore only its managed include;
# otherwise leave untouched installations alone.
[[ -f /var/lib/agentos/repository.json ]] || exit 0

/usr/bin/agentos-repository repair >/dev/null 2>&1 || {
  echo 'warning: could not preserve the configured AgentOS repository include' >&2
}
exit 0
