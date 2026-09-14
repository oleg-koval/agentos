#!/usr/bin/env bash
set -euo pipefail

if ! command -v pacman >/dev/null 2>&1 || ! command -v makepkg >/dev/null 2>&1; then
  echo "tests/key-rotation.sh must run inside the archlinux:base-devel container" >&2
  exit 1
fi

tmp="$(mktemp -d)"
# Allow the unprivileged rotation-builder user to traverse into $tmp to reach
# its own package source directory below; the gnupg homedirs still get their
# own 700 permissions independently.
chmod 711 "$tmp"
cleanup() {
  gpgconf --homedir "${signer_home:-/nonexistent}" --kill gpg-agent 2>/dev/null || true
  gpgconf --homedir "${client_home:-/nonexistent}" --kill gpg-agent 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

signer_home="$tmp/signer-gnupg"
client_home="$tmp/client-gnupg"
mkdir -m 700 "$signer_home" "$client_home"

for home in "$signer_home" "$client_home"; do
  echo 'allow-loopback-pinentry' > "$home/gpg-agent.conf"
done

export GNUPGHOME="$signer_home"
gpg --batch --passphrase '' --pinentry-mode loopback --quick-generate-key \
  'AgentOS Test Signer <signer@agentos.invalid>' ed25519 cert 0
primary_fpr="$(gpg --batch --with-colons --list-keys --fingerprint | awk -F: '$1=="fpr"{print $10; exit}')"
gpg --batch --passphrase '' --pinentry-mode loopback --quick-add-key "$primary_fpr" ed25519 sign 1d
subkey_fpr="$(gpg --batch --with-colons --list-keys --fingerprint "$primary_fpr" | awk -F: '$1=="fpr"{print $10}' | tail -n1)"
gpg --batch --armor --export "$primary_fpr" > "$tmp/agentos-signing.asc"

pacman-key --init --gpgdir "$client_home"
pacman-key --add "$tmp/agentos-signing.asc" --gpgdir "$client_home"
pacman-key --lsign-key "$primary_fpr" --gpgdir "$client_home"
trust_line="$(gpg --homedir "$client_home" --batch --with-colons --list-keys "$primary_fpr" | awk -F: '$1=="uid"{print $2; exit}')"
[[ "$trust_line" == "f" ]] || { echo "expected full trust after lsign, got '$trust_line'" >&2; exit 1; }

useradd -m -U rotation-builder 2>/dev/null || true
src_dir="$tmp/pkgsrc"
mkdir -p "$src_dir"
cat > "$src_dir/PKGBUILD" <<'EOF'
pkgname=testpkg
pkgver=1
pkgrel=1
arch=('any')
pkgdesc='test package for key rotation'
package() {
  mkdir -p "$pkgdir/usr/share/testpkg"
  echo hello > "$pkgdir/usr/share/testpkg/hello.txt"
}
EOF
chown -R rotation-builder:rotation-builder "$src_dir"
runuser -u rotation-builder -- bash -c "cd '$src_dir' && makepkg --nosign"

repo_dir="$tmp/repo"
mkdir -p "$repo_dir"
cp "$src_dir"/testpkg-1-1-*.pkg.tar.zst "$repo_dir/"
pkg="$(ls "$repo_dir"/testpkg-1-1-*.pkg.tar.zst)"
GNUPGHOME="$signer_home" gpg --batch --yes --detach-sign --local-user "$primary_fpr" "$pkg"
(cd "$repo_dir" && GNUPGHOME="$signer_home" repo-add --sign --key "$primary_fpr" testrepo.db.tar.gz "$(basename "$pkg")")

pacman_conf="$tmp/pacman.conf"
dbpath="$tmp/dbpath"
cachedir="$tmp/cache"
rootdir="$tmp/root"
mkdir -p "$dbpath" "$cachedir" "$rootdir"
cat > "$pacman_conf" <<EOF
[options]
RootDir = $rootdir
DBPath = $dbpath
CacheDir = $cachedir
GPGDir = $client_home
SigLevel = Required
[testrepo]
SigLevel = Required
Server = file://$repo_dir
EOF

run_pacman() {
  pacman --config "$pacman_conf" "$@"
}

run_pacman -Sy
run_pacman -S --noconfirm testpkg
echo "install while valid: OK"

# pacman verifies signatures via libgpgme, which resolves the gpg binary at a
# path decided when gpgme was built, not via PATH lookup at runtime. A gpg
# wrapper placed first on PATH is therefore silently ignored by pacman, and
# -Sy/-S would succeed even against an "expired" subkey. To make the faked
# time authoritative for the whole client keyring (both pacman's libgpgme
# calls and a plain `gpg --verify`), write a faked-system-time directive into
# the client homedir's gpg.conf for the duration of this phase, and remove it
# before the recovery phase below. This is what actually forces the expiry to
# be observed; the PATH wrapper is kept only so the `gpg --verify` invocation
# below uses the identical mechanism as the pacman assertions, keeping the
# comparison between them honest.
fake_bin="$tmp/fake-bin"
mkdir -p "$fake_bin"
real_gpg="$(command -v gpg)"
future_epoch="$(date -u -d '+2 days' +%s)"
cat > "$fake_bin/gpg" <<EOF
#!/usr/bin/env bash
exec "$real_gpg" --faked-system-time=${future_epoch}! "\$@"
EOF
chmod +x "$fake_bin/gpg"

enable_fake_time() { echo "faked-system-time ${future_epoch}!" >> "$client_home/gpg.conf"; }
disable_fake_time() { sed -i '/^faked-system-time/d' "$client_home/gpg.conf"; }

rm -rf "$rootdir"/*
enable_fake_time
set +e
PATH="$fake_bin:$PATH" run_pacman -Sy >"$tmp/expired-sy.log" 2>&1
sy_status=$?
set -e
disable_fake_time
[[ "$sy_status" -ne 0 ]] || { echo "expected -Sy to fail once the signing subkey is expired" >&2; cat "$tmp/expired-sy.log" >&2; exit 1; }
grep -Fqi 'is expired' "$tmp/expired-sy.log"

run_pacman -Sy
enable_fake_time
set +e
PATH="$fake_bin:$PATH" run_pacman -S --noconfirm testpkg >"$tmp/expired-s.log" 2>&1
s_status=$?
set -e
disable_fake_time
[[ "$s_status" -ne 0 ]] || { echo "expected -S to fail once the signing subkey is expired" >&2; cat "$tmp/expired-s.log" >&2; exit 1; }
grep -Fqi 'is expired' "$tmp/expired-s.log"

set +e
"$fake_bin/gpg" --homedir "$client_home" --verify "$pkg.sig" "$pkg" >"$tmp/gpg-verify.log" 2>&1
verify_status=$?
set -e
[[ "$verify_status" -eq 0 ]] || { echo "expected gpg --verify alone to still accept the expired signature" >&2; cat "$tmp/gpg-verify.log" >&2; exit 1; }
grep -Fqi 'good signature' "$tmp/gpg-verify.log"
grep -Fqi 'expired' "$tmp/gpg-verify.log"
echo "gpg --verify accepts an expired signature while pacman refuses it: OK"

# Recovery phase. --quick-set-expire runs against the signer's real clock
# (its GNUPGHOME carries no faked-system-time), so it genuinely extends the
# subkey's real expiry. The final verification below must still be checked
# from the client's simulated future (the same fake_epoch used for the
# expired-key phase), not real time: real time never actually reaches the
# original 1-day subkey expiry during this script's short runtime, so
# checking under real time would pass regardless of whether the recovery
# steps ran at all. Re-enabling the faked time here is what makes this
# check prove the recovery, rather than passing vacuously.
GNUPGHOME="$signer_home" gpg --batch --passphrase '' --pinentry-mode loopback --quick-set-expire "$primary_fpr" 30d "$subkey_fpr"
GNUPGHOME="$signer_home" gpg --batch --armor --export "$primary_fpr" > "$tmp/agentos-signing-refreshed.asc"
pacman-key --add "$tmp/agentos-signing-refreshed.asc" --gpgdir "$client_home"

trust_line_after="$(gpg --homedir "$client_home" --batch --with-colons --list-keys "$primary_fpr" | awk -F: '$1=="uid"{print $2; exit}')"
[[ "$trust_line_after" == "f" ]] || { echo "trust dropped from full after a plain pacman-key --add, got '$trust_line_after'" >&2; exit 1; }

enable_fake_time
PATH="$fake_bin:$PATH" run_pacman -Sy
PATH="$fake_bin:$PATH" run_pacman -S --noconfirm testpkg
disable_fake_time
echo "recovered with a plain pacman-key --add after --quick-set-expire, no re-lsign, no delete: OK"

echo "key-rotation.sh test passed."
