# P0 package migration and recovery runbook

This runbook is for migrating a source-installed AgentOS workstation to the
signed packages. It deliberately uses a targeted migration path; do not use
`pacman --overwrite '*'`.

## Before the first package transaction

Run these checks over the existing SSH/Tailscale connection and stop if SSH,
Tailscale, or configured KRDP is unhealthy:

```bash
hostname
whoami
findmnt /
systemctl is-active sshd tailscaled
tailscale ip -4
systemctl --user is-active app-org.kde.krdpserver.service
ss -ltn | grep -E ':(22|3389)\b'
sudo rollback-workstation status
```

If the current root is an `@rollback-*` subvolume, do not reboot or delete the
rollback state during migration. It is recovery evidence, not a successful
candidate validation. Confirm the normal boot entry and snapshot first.

Bootstrap the public release key and verify the exact fingerprint before
configuring pacman:

```bash
AGENTOS_RELEASE_BASE_URL='https://your-agentos-release-host.example/agentos'
curl -fsSL "${AGENTOS_RELEASE_BASE_URL}/agentos-repo-public.asc" \
  -o /tmp/agentos-repo-public.asc
gpg --show-keys --with-fingerprint /tmp/agentos-repo-public.asc
test "$(gpg --show-keys --with-colons /tmp/agentos-repo-public.asc |
  awk -F: '$1 == "fpr" {print $10; exit}')" = \
  3060184CFC884D14CB1D54F9CA25144B4E4DBA8E
sudo agentos-repository configure \
  "${AGENTOS_RELEASE_BASE_URL}/\$arch" \
  /tmp/agentos-repo-public.asc \
  3060184CFC884D14CB1D54F9CA25144B4E4DBA8E
sudo agentos-repository status
```

The command writes `/etc/pacman.d/agentos.conf` and one Include line in
`/etc/pacman.conf`. It does not replace the pacman configuration.

## Install and migrate

Create the normal pacman recovery snapshot before installing packages, then
install only the signed runtime and shell packages. The shell package owns its
wallpaper under `/usr/share/agentos`; its install migration removes only the
known unmanaged legacy wallpaper path.

```bash
sudo btrfs-pre-pacman-snapshot
sudo pacman -Syy
sudo pacman -S agentos-runtime agentos-shell
sudo systemctl daemon-reload
systemctl --user daemon-reload
systemctl --user enable --now agentosd.service agentos-herdr-bridge.service
sudo systemctl enable agentos-boot-health.service agentos-weekly-update.timer
sudo systemctl start agentos-boot-health.service || true
```

Do not install `agentos-runtime-debug` as part of the normal runtime.

Verify package ownership and paths before any reboot:

```bash
pacman -Q agentos-base agentos-runtime agentos-shell
pacman -Qo /usr/bin/agentos /usr/bin/agentosd /usr/bin/agentos-boot-health
pacman -Qo /usr/share/agentos/wallpaper.svg
test ! -e /usr/local/bin/agentosd
test ! -e /etc/systemd/user/agentosd.service
grep -R '/usr/local' /usr/lib/systemd /usr/share/libalpm/hooks && exit 1 || true
systemctl is-enabled agentos-boot-health.service agentos-weekly-update.timer
systemctl --user is-enabled agentosd.service agentos-herdr-bridge.service
agentos health
sudo agentos-boot-health status
```

If the repository Include is missing after an Arch or AgentOS update, repair
only AgentOS configuration:

```bash
sudo agentos-repository repair
sudo agentos-repository status
```

`repair` refuses to proceed if the stored trusted fingerprint is missing from
the pacman keyring. Re-run the explicit `configure` bootstrap in that case.

## Candidate/reboot gate

Do not reboot until the candidate state, recovery snapshot, and remote paths
are visible in the output above. Once VM candidate/rollback tests are green,
the physical validation is:

```bash
sudo systemctl is-enabled agentos-boot-health.service
sudo test -f /usr/bin/agentos-boot-health
sudo test -f /usr/lib/systemd/system/agentos-boot-health.service
sudo agentos-boot-health status
sudo systemctl reboot
```

After reconnecting, verify the boot gate and all protected access paths:

```bash
findmnt /
sudo systemctl status agentos-boot-health.service --no-pager -l
systemctl --user is-active agentosd.service agentos-herdr-bridge.service
systemctl is-active sshd tailscaled
tailscale ip -4
systemctl --user is-active app-org.kde.krdpserver.service
ss -ltn | grep -E ':(22|3389)\b'
agentos health
sudo agentos-boot-health status
```

The observed machine on 2026-08-23 was booted from
`@rollback-20260823-093626` with legacy `/usr/local` runtime, no installed
AgentOS package database entries, no boot-health unit, and an inactive Herdr
bridge. That state must be treated as an invalid historical candidate until
the signed package install and post-reboot checks above succeed. Preserve the
old `pre-pacman-*` snapshot until that validation is complete.
