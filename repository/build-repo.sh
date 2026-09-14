#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${AGENTOS_REPO_OUT:-$ROOT/out/repo/x86_64}"
SIGN_KEY="${AGENTOS_SIGN_KEY:-}"
mkdir -p "$OUT"
rm -f "$OUT"/*.pkg.tar.zst "$OUT"/*.pkg.tar.zst.sig "$OUT"/agentos.db* "$OUT"/agentos.files*

for pkgdir in "$ROOT"/packages/agentos-*; do
  [[ -f "$pkgdir/PKGBUILD" ]] || continue
  echo "==> Building $(basename "$pkgdir")"
  (
    cd "$pkgdir"
    rm -f ./*.pkg.tar.zst ./*.pkg.tar.zst.sig
    # AgentOS package jobs run in a prepared Arch builder image. --nodeps avoids
    # makepkg attempting privileged dependency installation as the build user.
    makepkg --nodeps --noconfirm --cleanbuild
    cp -f ./*.pkg.tar.zst "$OUT/"
  )
done

shopt -s nullglob
packages=("$OUT"/*.pkg.tar.zst)
shopt -u nullglob
(( ${#packages[@]} > 0 )) || { echo 'No AgentOS packages were built.' >&2; exit 1; }

if [[ -n "$SIGN_KEY" ]]; then
  for pkg in "${packages[@]}"; do
    gpg --batch --yes --detach-sign --local-user "$SIGN_KEY" "$pkg"
  done
fi

repo-add "$OUT/agentos.db.tar.gz" "${packages[@]}"

if [[ -n "$SIGN_KEY" ]]; then
  gpg --batch --yes --detach-sign --local-user "$SIGN_KEY" "$OUT/agentos.db.tar.gz"
  gpg --batch --yes --detach-sign --local-user "$SIGN_KEY" "$OUT/agentos.files.tar.gz"
fi

# repo-add creates agentos.db and agentos.files as symlinks to the tarballs.
# Static artifact/HTTP hosts may not preserve symlinks, so replace those aliases
# with regular files. Remove the symlinks first, otherwise cp detects source and
# destination as the same inode and exits 1.
rm -f "$OUT/agentos.db" "$OUT/agentos.files" "$OUT/agentos.db.sig" "$OUT/agentos.files.sig"
cp "$OUT/agentos.db.tar.gz" "$OUT/agentos.db"
cp "$OUT/agentos.files.tar.gz" "$OUT/agentos.files"
if [[ -n "$SIGN_KEY" ]]; then
  cp "$OUT/agentos.db.tar.gz.sig" "$OUT/agentos.db.sig"
  cp "$OUT/agentos.files.tar.gz.sig" "$OUT/agentos.files.sig"
fi

echo "AgentOS package repository built at $OUT"
