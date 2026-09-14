# AgentOS troubleshooting

Start with read-only checks. These commands do not repair, reboot, or change
access policy.

```bash
agentos health
agentos state
agentos repository status
systemctl --failed
systemctl --user --failed
```

## `sudo` says the password is wrong

Run `sudo -v` on the target machine and type the password for that Linux user.
When using SSH, the prompt belongs to the remote host. Check that the SSH
login name is correct with `whoami`; do not paste a password into a command.
An expired or locked account needs provider-console or another administrator
recovery path. AgentOS does not bypass sudo authentication.

## SSH works but a command is not found

A source checkout command is not automatically on `PATH`. Use the packaged
absolute command when available:

```bash
command -v agentos
command -v sync-workstation || true
ls -l /usr/local/bin/sync-workstation /usr/bin/agentos 2>/dev/null || true
```

The supported packaged update path is `agentos update --apply`. A development
checkout may use `/usr/local/bin/sync-workstation` after its installation step;
if it is absent, inspect the update output before recreating symlinks.

## AgentOS API or Home is unavailable

```bash
curl -fsS http://127.0.0.1:4787/v1/healthz
systemctl --user status agentosd.service agentos-home.service --no-pager
journalctl --user -u agentosd.service -u agentos-home.service -n 100 --no-pager
```

On a VPS, Home is optional until a Wayland session exists. The API and
`agentosd` user service are still required. Do not expose port 4787; it is a
localhost-only privileged control boundary.

## First-run configuration is missing

If `agentos config plan` reports that `/etc/agentos/config.yaml` is missing,
create the conservative baseline and inspect it before enabling optional
capabilities:

```bash
sudo agentos config init
agentos config plan
```

Existing configuration files and symlinks are preserved by the initializer.

## Repository, signature, or update failure

```bash
agentos repository status
agentos update --check
sudo pacman -Syy
```

Confirm that the managed Include is present, `SigLevel = Required` is set, and
the published fingerprint matches the onboarding documentation. Do not trust
an unverified key or disable signature checking. If a package transaction
reports a dependency mismatch, refresh the package database and allow the
repository to publish a consistent package set; do not force `-Rdd` or partial
upgrades.

The last per-user check is stored under
`~/.local/state/agentos/update-check.json`; the guarded apply result is stored
under `/var/lib/agentos/update-result.json`. Both contain bounded status text,
not the package-manager transcript. A `reboot-required` result clears from the
runtime view only after the machine boot ID changes; AgentOS never reboots as
part of update apply.

If desktop update notifications are missing, inspect the per-user timer and
service without applying an update:

```bash
systemctl --user status agentos-update-notify.timer --no-pager
systemctl --user status agentos-update-notify.service --no-pager
```

## Migration, hardware, or firmware status is unavailable

```bash
agentos migrate status --json
agentos hardware --json
agentos maintenance
```

A failed migration remains recorded and blocks later migrations in that scope;
fix the first failing migration before retrying the same explicit scope. An
`unavailable` hardware check means AgentOS could not prove readiness. On a VPS,
physical-only checks correctly report `unsupported`. Firmware support remains
optional: install `fwupd` only through the separately confirmed enable action,
and never enable a firmware remote or apply an update merely to clear a status.

## Failed services or a bad convergence

```bash
systemctl --failed
systemctl status workstation-health-check.service --no-pager
journalctl -b -p warning..alert --no-pager
agentos boot-status
```

Capture the first failing unit and its journal. The health check is
diagnostic; restarting a service is a separate operator decision. A candidate
boot marked for validation must be allowed to complete its one-shot health
gate before manual rollback work.

## Rollback and VPS reset

Inspect desktop recovery state before staging anything:

```bash
agentos recovery --json
```

Only a point labelled `boot-safe` can be staged. The Recovery Center launches
stage and cancel in a visible terminal with separate confirmation; neither
action reboots or deletes data. If state is `unavailable`, preserve the normal
boot entries and inspect the first reported metadata or manifest error before
using the lower-level rollback command.

For an AgentOS package/repository configuration reset on a VPS:

```bash
sudo agentos-vps-install --reset
```

This restores the newest saved installer configuration but does not remove
packages, revoke keys, or roll back the operating system. For a failed boot or
filesystem state, use the provider snapshot/console or the documented Btrfs
rollback procedure. Preserve SSH and the provider console until the machine is
verified healthy.

## Wi-Fi, Bluetooth, mouse, and other system settings

Open AgentOS Home → System. Available controls launch KDE's own settings
panels and retain normal Linux/Polkit authorization. On a headless VPS those
controls may be unavailable by design. Use the provider's network console if
SSH is lost; do not change firewall or network policy blindly over a remote
connection.

## What to collect for support

```bash
agentos support
```

Review the generated Markdown file before sharing it. Logs are excluded by
default; add `--include-logs` only when a bounded warning/error excerpt is
needed. Nothing is uploaded automatically. Include the host role (physical or
VPS), provider if applicable, and whether the failure happened before or after
a reboot. Redact passwords, private keys, tokens, raw prompts, and unrelated
personal paths.

Reliability telemetry is disabled by default. Enable it only if you consent to
anonymous, low-cardinality reliability events being queued locally:

```bash
agentos telemetry status
agentos telemetry enable
agentos telemetry disable
```
