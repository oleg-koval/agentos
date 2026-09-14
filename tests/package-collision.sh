#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail=0

# G1 and G2 are two named gaps: the agentos-runtime .install pre_install()
# must know about both legacy paths so pacman -S agentos-runtime can migrate
# a machine that already ran the checkout installer.
grep -Fq '/usr/local/sbin/agentos-repository' packages/agentos-runtime/agentos-runtime.install || {
  echo 'G1 not fixed: /usr/local/sbin/agentos-repository missing from agentos-runtime.install pre_install() removal list' >&2
  fail=1
}
grep -Fq '/usr/share/agentos/AGENTS.md' packages/agentos-runtime/agentos-runtime.install || {
  echo 'G2 not fixed: /usr/share/agentos/AGENTS.md missing from agentos-runtime.install pre_install() removal list' >&2
  fail=1
}

# 1. No path apply-system-policy.sh writes is also owned by a PKGBUILD
#    package(). A straight collision means pacman -S will refuse to
#    overwrite a file it does not own.
mapfile -t policy_paths < <(grep -oE '(^|[[:space:]])(/etc|/usr|/var)[A-Za-z0-9_./@-]*' apply-system-policy.sh | sed -E 's/^[[:space:]]*//' | sort -u)
mapfile -t package_paths < <(grep -hoE '"\$pkgdir(/[A-Za-z0-9_.@/-]+)"' packages/*/PKGBUILD | sed -E 's/^"\$pkgdir//; s/"$//' | sort -u)

for p in "${policy_paths[@]}"; do
  for q in "${package_paths[@]}"; do
    if [[ "$p" == "$q" ]]; then
      echo "apply-system-policy.sh writes $p, which packages/*/PKGBUILD also installs" >&2
      fail=1
    fi
  done
done

# 2. Every /usr/local/{bin,sbin} path any checkout script writes either
#    appears in a .install pre_install() removal list, or has no packaged
#    equivalent (and is therefore legitimate checkout-owned surface).
mapfile -t local_writes < <(grep -hoE '/usr/local/(bin|sbin)/[A-Za-z0-9_.-]+' ./*.sh 2>/dev/null | sort -u)
mapfile -t removal_paths < <(grep -hoE '/usr/local/(bin|sbin)/[A-Za-z0-9_.-]+' packages/*/*.install | sort -u)

for local_path in "${local_writes[@]}"; do
  name="$(basename "$local_path")"
  has_package_equivalent=0
  for pp in "${package_paths[@]}"; do
    [[ "$(basename "$pp")" == "$name" ]] && has_package_equivalent=1
  done
  if (( has_package_equivalent )); then
    is_removed=0
    for rp in "${removal_paths[@]}"; do
      [[ "$rp" == "$local_path" ]] && is_removed=1
    done
    if (( ! is_removed )); then
      echo "$local_path shadows a packaged $name and is missing from any .install pre_install() removal list" >&2
      fail=1
    fi
  fi
done

(( fail == 0 )) || exit 1
echo 'Package collision contract passed.'
