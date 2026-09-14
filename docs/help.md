# AgentOS help

AgentOS is a portable workstation layer on top of Arch Linux and KDE Plasma.
Use the commands below from a terminal. They are safe to run over SSH unless
the command says that it changes the machine.

## First checks

```bash
agentos health                 # daemon, services, remote access and updates
agentos state                  # current projects, agents and attention items
agentos sessions               # persistent agent sessions
agentos hardware --json        # read-only hardware readiness
agentos repository status      # signed repository and Include state
agentos update --check         # available AgentOS and Arch updates
agentos maintenance            # typed maintenance capabilities and actions
agentos migrate status --json  # pending/applied system and user migrations
agentos welcome                # first-run command summary
sudo agentos config init       # create the conservative first-run config
agentos config plan            # inspect the desired machine state
agentos support                # create a local redacted support report
agentos telemetry status       # privacy status; disabled by default
```

AgentOS Home is the graphical workspace. Its System view shows whether the
machine is physical or a VPS and exposes available KDE settings panels. On a
headless VPS, use SSH and these commands; the local API is intentionally not
exposed to the network.

For a new desktop installation, open **System** and work from top to bottom:
review **Health** and **Hardware readiness**, use **Update Center** to check the
signed channel, and review **Recovery Center** before risky changes. **Support
& privacy** can run Doctor or create a redacted local report without uploading
it. Native AgentOS Home and its Chromium fallback use the same localhost state
and fixed action allow-list. Status is always written as text, so color is not
required to understand it; unavailable controls explain what is missing.

`agentos maintenance` prints the versioned maintenance contract used by the
graphical shell and localhost API. A domain marked `unavailable` is not yet
implemented on that installation. Listed actions are fixed, allow-listed
operations; the API does not accept arbitrary commands.

Versioned migrations are package-owned, ordered repairs. Inspect both scopes
with `agentos migrate status --json`. Applying always names one scope:
`sudo agentos migrate apply --scope system --json` for machine-wide work, or
`agentos migrate apply --scope user --json` for the current user. Failed work
remains pending and later migrations do not run.

At graphical login, AgentOS stays silent when no user migration is pending. If
work is pending or previously failed, one notification offers `Review and
apply`; selecting it opens the same user-scope command in a visible terminal.
Closing the notification does not apply anything.

## Common actions

```bash
agentos project open NAME      # focus or register a project
agentos agent start codex      # start an enabled agent
agentos agent start claude
agentos agent start hermes
agentos agent start herdr
agentos store list             # available agents, models and capabilities
agentos plan                   # capability status
```

Interactive installation uses arrow-key menus for optional tools, target-disk
selection, and erase confirmation. The default local account is `agent`; the
installer also asks for LUKS confirmation, an encryption passphrase, and a
separate Linux login password. Erase confirmation defaults to Cancel. Scripted
installs can still use `--opencode --ide IDE`, where supported IDE values are
`none`, `cursor`, `vscode`, and `webstorm`.

## Hardware readiness

Run `agentos hardware` for a concise report or `agentos hardware --json` for
the typed `agentos.hardware/v1` model used by AgentOS Home. It inspects only
architecture, machine role, UEFI/systemd-boot, root filesystem and recovery
eligibility, NetworkManager state, graphical session type, and whether
`fwupdmgr` is present. The command does not install packages, enable firmware
remotes, upload reports, apply firmware, change BIOS settings, or reboot.

Checks use `ready`, `warning`, `blocked`, `unsupported`, and `unavailable`.
Physical-only checks are `unsupported` on a VPS. Missing tools and malformed
command output remain `unavailable`; they are never treated as ready. Firmware
support is optional and is enabled separately on demand.

Firmware operations remain separate from normal AgentOS package updates:

```bash
agentos hardware firmware-enable                 # install fwupd after sudo/pacman confirmation
agentos hardware firmware-check --json           # refresh enabled remotes, then inspect JSON state
sudo agentos hardware firmware-apply --confirm   # apply available firmware; never auto-reboot
```

`firmware-enable` installs only the Arch package. AgentOS does not enable a
firmware remote, upload device/history reports, weaken fwupd safety checks, or
reboot. Enabling a remote such as `lvfs` is a separate operator decision made
directly with `sudo fwupdmgr enable-remote lvfs`. Apply outcomes are stored in
`/var/lib/agentos/firmware-result.json`; `reboot_known: false` means the update
ran but fwupd could not determine whether a reboot is still required.

## Updates and recovery

Inspect before changing anything:

```bash
agentos update --check
agentos boot-status
agentos recovery --json         # typed current/staged/next-boot state
agentos rollback                # compatibility alias for recovery inspection
```

The check verifies the active channel's signed release manifest, compares its
package versions with the installed AgentOS packages, and records a bounded
result for AgentOS Home. It does not install packages. Results distinguish
up-to-date, available, check failure, apply failure, success, and a required
manual reboot.

On a desktop, open **System → Update Center** or select the AgentOS update
status in the Plasma panel. **Check** is read-only; **Update now** opens the
visible, guarded `agentos update --apply` flow and retains normal authorization.
One notification is shown per release or final outcome. AgentOS never restarts
the machine automatically.

The weekly stable update uses the configured signed repository and attempts a
boot-consistent recovery snapshot before package mutation. If a recovery point
was created and the post-update check fails, it is staged for one-shot rollback;
a successful update arms the next-boot health gate. Snapshot-creation failure
does not currently abort the update. Do not delete snapshots or edit boot entries
while a candidate is armed. Read [troubleshooting](troubleshooting.md) before
recovery work.

Recovery state uses the `agentos.recovery/v1` schema and labels each point
`boot-safe` only when its matching boot bundle passes manifest verification.
Root-only points remain visible but cannot be staged through AgentOS. Staging
and cancellation require separate confirmation and sudo authorization:

```bash
sudo agentos recovery stage pre-pacman-YYYYMMDD-HHMMSS --confirm
sudo agentos recovery cancel --confirm
```

Staging changes only the next boot. It does not reboot, delete a snapshot, or
rewrite the normal boot entries; cancellation also remains separate from
reboot. Recovery metadata is readable by the desktop, while mutation remains
inside the existing privileged `rollback-workstation` boundary.

## Remote access

SSH is the initial access path. Tailscale and KRDP are optional and must be
validated explicitly during onboarding. A normal `sudo -v` asks for the Linux
user password on the host where it runs; it does not use the password from the
operator's laptop. Never put a password in an SSH command or script.

```bash
agentos remote
agentos-onboarding --local
agentos-vps-install --help       # guided signed bootstrap options
```

## More help

- [VPS installation and onboarding](vps-onboarding.md)
- [VPS provider validation](vps-providers.md)
- [Friend-system acceptance](friend-system-acceptance.md)
- [Troubleshooting](troubleshooting.md)
- [Release and promotion policy](release-promotion.md)

When reporting a problem, include the command, the first error line, and the
read-only output of `agentos health`, `agentos repository status`, and the
relevant `systemctl` or `journalctl` command. Do not include passwords,
private keys, repository credentials, or raw agent prompts.

For a shareable local report, run `agentos support`. Review the generated file
before attaching it to a GitHub issue. `agentos support --include-logs` is
explicitly opt-in and still writes locally; AgentOS never uploads the report.

Reliability telemetry is disabled by default. `agentos telemetry enable` only
permits low-cardinality anonymous events to be queued locally. Upload requires
an explicitly configured HTTPS endpoint and a manual `agentos telemetry upload`
command. It does not collect prompts, commands, tool output, paths, usernames,
project names, hostnames, addresses, tokens, or document contents.
