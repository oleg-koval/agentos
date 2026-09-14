#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# 1. Every $SOURCE_DIR/<path> apply-system-policy.sh dereferences must be
#    something copy_bootstrap_assets() in install.sh actually copies into
#    /mnt/root.
# .git is probed with -d for optional git-remote autodetection, not required at runtime.
mapfile -t required_refs < <(grep -oE '\$SOURCE_DIR/[A-Za-z0-9_./-]+' apply-system-policy.sh | sed 's#^\$SOURCE_DIR/##' | sort -u | grep -v '^\.git$')

loop_block="$(awk '/for file in \\/{flag=1} flag{print} flag && /; do/{exit}' install.sh)"
mapfile -t loop_files < <(printf '%s\n' "$loop_block" | tr -d '\\' | tr -s '[:space:]' '\n' | grep -E '\.sh$' | sort -u)

mapfile -t cp_targets < <(grep -oE 'cp (-R )?"\$SCRIPT_DIR/[A-Za-z0-9_./-]+"' install.sh | sed -E 's#.*"\$SCRIPT_DIR/([^"]+)"#\1#' | sort -u)

is_copied() {
  local ref="$1" f
  for f in "${loop_files[@]}" "${cp_targets[@]}"; do
    [[ "$ref" == "$f" || "$ref" == "$f"/* ]] && return 0
  done
  return 1
}

missing=0
for ref in "${required_refs[@]}"; do
  if ! is_copied "$ref"; then
    echo "apply-system-policy.sh needs \$SOURCE_DIR/$ref but copy_bootstrap_assets() never copies it" >&2
    missing=1
  fi
done

# 2. Every ExecStart= path in a unit some delivery path installs must be a
#    path some delivery path actually populates.
mapfile -t provided < <(grep -hoE '"\$pkgdir(/[A-Za-z0-9_.@/-]+)"' packages/*/PKGBUILD | sed -E 's/^"\$pkgdir//; s/"$//' | sort -u)

is_provided() {
  local path="$1" p
  for p in "${provided[@]}"; do
    [[ "$path" == "$p" ]] && return 0
  done
  return 1
}

for unit in systemd/system/*.service systemd/system/*.timer systemd/user/*.service systemd/user/*.timer; do
  [[ -f "$unit" ]] || continue
  # Timer units carry no ExecStart=, so grep exits 1 on them. Under pipefail that
  # would kill the loop, so absorb it and skip the unit instead.
  exec_line="$(grep -m1 '^ExecStart=' "$unit" || true)"
  [[ -n "$exec_line" ]] || continue
  exec_path="$(printf '%s\n' "${exec_line#ExecStart=}" | awk '{print $1}')"
  [[ -n "$exec_path" ]] || continue
  case "$exec_path" in
    /usr/local/*)
      echo "$unit still points ExecStart at $exec_path; package-owned units must not reference /usr/local" >&2
      missing=1
      ;;
    /usr/*)
      if ! is_provided "$exec_path"; then
        echo "$unit ExecStart references $exec_path, which no PKGBUILD package() installs" >&2
        missing=1
      fi
      ;;
  esac
done

(( missing == 0 )) || exit 1
echo 'Install completeness contract passed.'
