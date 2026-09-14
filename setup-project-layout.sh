#!/usr/bin/env bash
# Create a deliberately boring, shallow source-tree layout for daily development.
set -euo pipefail

if [[ ${EUID} -eq 0 ]]; then
  echo 'Run setup-project-layout as the workstation user, not root.' >&2
  exit 1
fi

SRC_ROOT="${SRC_ROOT:-$HOME/src}"
WORKTREE_ROOT="${WORKTREE_ROOT:-$HOME/worktrees}"
SCRATCH_ROOT="${SCRATCH_ROOT:-$HOME/scratch}"
BUILD_ROOT="${BUILD_ROOT:-$HOME/build}"

for dir in "$SRC_ROOT" "$WORKTREE_ROOT" "$SCRATCH_ROOT" "$BUILD_ROOT"; do
  install -d -m 755 "$dir"
done

# Keep canonical clones in ~/src and parallel/agent worktrees somewhere obvious.
# Herdr defaults to ~/.herdr/worktrees, so point that path at the shared worktree
# root without touching an existing real directory that may contain user state.
install -d -m 700 "$HOME/.herdr"
herdr_worktrees="$HOME/.herdr/worktrees"
if [[ ! -e "$herdr_worktrees" && ! -L "$herdr_worktrees" ]]; then
  ln -s "$WORKTREE_ROOT" "$herdr_worktrees"
elif [[ -L "$herdr_worktrees" ]]; then
  current_target="$(readlink "$herdr_worktrees")"
  if [[ "$current_target" != "$WORKTREE_ROOT" ]]; then
    echo "Herdr worktree link already points to $current_target; leaving it unchanged." >&2
  fi
elif [[ -d "$herdr_worktrees" ]]; then
  if find "$herdr_worktrees" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    echo "Herdr already has worktrees in $herdr_worktrees; leaving that directory unchanged." >&2
  else
    rmdir "$herdr_worktrees"
    ln -s "$WORKTREE_ROOT" "$herdr_worktrees"
  fi
else
  echo "Unexpected path at $herdr_worktrees; leaving it unchanged." >&2
fi

cat <<EOF
Project layout ready:
  $SRC_ROOT       canonical repository clones
  $WORKTREE_ROOT  parallel branches / agent worktrees
  $SCRATCH_ROOT   disposable experiments
  $BUILD_ROOT     generated out-of-tree build output

Keep repositories shallow under ~/src, for example:
  ~/src/agentos
  ~/src/promptctl
  ~/src/linux

Do not nest by employer, language, or Git host unless a real collision forces it.
EOF
