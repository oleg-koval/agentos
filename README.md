# AgentOS

Community beta preparation and acceptance gates: [community beta](docs/community-beta.md).

Reproducible Arch Linux workstation setup for physical machines and VPS hosts.

> **Warning:** `install.sh` erases the configured target disk. Set `DISK`
> explicitly or choose it at the interactive prompt. Review and confirm the
> target before running it.

## What it does

- full-disk LUKS2 encryption by default
- Btrfs root with dedicated subvolumes and zstd compression
- `linux` + `linux-lts`, CPU-vendor-detected microcode (`amd-ucode`/`intel-ucode`), Mesa/Vulkan acceleration
- KDE Plasma/Wayland, native Qt/QML Workspace, Kitty, KRDP, Chromium Home fallback
- Neovim, zsh, tmux, Atuin, Yazi and the portable dotfile layer
- Codex, Qwen Code, Claude Code, Hermes Agent, Playwright CLI and Ollama
- SSH hardening, UFW and Tailscale
- Btrfs pre-pacman root snapshots **plus matching /boot bundles**
- boot-consistent one-shot rollback without rewriting the normal boot entries
- guarded weekly stable-channel updates plus non-mutating maintenance reports
- read-only hardware readiness plus separately authorized, on-demand fwupd support
- daily health checks with optional Hermes/Telegram failure alerts
- Hermes migration helpers, persistent systemd user operation and age-encrypted backups
- Restic backup scaffolding plus monthly integrity and restore smoke tests
- CI for shell syntax, ShellCheck, package-manifest validation and mocked integration tests
- typed Go operations for updates, recovery transactions, repository/capability policy, configuration apply and remote validation
- read-only private-VPS onboarding validation with signed-repository and local-API checks
- one explicit convergence command: `sync-workstation`

## Files

- `make-usb.sh` — build the Arch installer USB on macOS
- `packages.txt` — canonical Arch package manifest
- `install.sh` — partition, format and install the base system
- `bootstrap.sh` — configure the installed system in `arch-chroot`
- `apply-system-policy.sh` — install timers, pacman hooks, health/recovery commands and linger policy
- `sync-workstation.sh` — pull `main` and converge the machine
- `update-workstation.sh` — explicit mutating Arch/tool update invoked by `sync-workstation`
- `install-dotfiles.sh` — install/relink managed dotfiles
- `install-agent-tools.sh` — install/update Claude, Hermes, browser automation and explicitly selected optional tools
- `agentos-native-event.sh` — normalize native Claude Code, Codex, Hermes and Herdr hook input
- `maintenance-check.sh` — non-mutating weekly update/health report
- `workstation-doctor.sh` — consolidated health status and actionable-failure detection
- `workstation-alert.sh` — send deduplicated failure alerts via Hermes messaging
- `agentos-support.sh` — create a local redacted support report
- `agentos-telemetry.sh` — manage opt-in reliability events and explicit uploads
- `rollback-workstation.sh` — stage/cancel boot-consistent one-shot Btrfs rollback boots
- `hermes-backup.sh` — age-encrypted portable Hermes backup helper
- `migrate-hermes.sh` — import plain or age-encrypted Hermes backups
- `enable-hermes-gateway.sh` — install/start Hermes as an always-on user service
- `restic-verify.sh` — verify the Restic repository and restore `/etc/hostname` as a smoke test
- `agentos-onboarding.sh` — validate a VPS over SSH without changing access or system state
- `agentos-vps-install.sh` — safely bootstrap an already-provisioned Arch VPS from the signed repository
- `docs/help.md` and `docs/troubleshooting.md` — offline onboarding, recovery and support guidance
- `agentos-native-workspace.sh` — native Qt/QML Workspace client used by the default graphical surface
- `.agents/skills/` — canonical AgentOS operator and maintenance skills for Codex, Claude Code and Hermes
- `systemd/` — system and user timer units
- `pacman-hooks/` — Btrfs snapshot/prune hooks
- `tests/static.sh` — static CI validation
- `tests/integration.sh` — mocked rollback and encrypted-backup integration coverage

The source repository is configurable. Set `AGENTOS_REPO` before the first
`sync-workstation` run, or let the installer persist the checkout's origin to
`/etc/agentos/repository-url`; no personal repository owner is assumed.

### Native agent events

`agentos-native-event` is an observer-only adapter for native Claude Code and
Codex lifecycle hooks, Hermes plugin hooks, and the native agents running under
Herdr. It forwards bounded lifecycle, tool, approval and file-change metadata
to `agentosd`; raw prompts, commands and tool results are not persisted by the
adapter. `install-agent-tools --update` merges the Claude/Codex hook entries
idempotently and enables the bundled Hermes `agentos-observability` plugin when
Hermes has been configured.

### AgentOS skills

The repository carries focused Agent Skills under `.agents/skills/`:
`agentos-operator` for ordinary workstation/project/session operation and
`agentos-maintainer` for explicitly authorized updates and recovery. The
`agentos-system` for the provider-neutral system guide. The runtime package
installs canonical copies under `/usr/share/agentos/skills` and the guide at
`/usr/share/agentos/AGENTS.md`.
Running `install-agent-tools --update` creates non-destructive links for the
current user in the Codex, Claude Code, and Hermes skill locations; existing
user-owned skills are preserved.

File changes use a bounded, client-compatible shape: `operation` is one of
`added`, `modified`, `deleted` or `renamed`; content before/after values are
stored as `sha256:<digest>;bytes:<count>`; and rename paths are stored as
`path:<path>`. Raw file contents are never forwarded to the AgentOS event
store.

The runtime keeps the recent event window in `/v1/events` and maintains an
indexed history beyond that window through `GET /v1/logs`. Query logs with
`kind`, `agent`, `session`, `project` or text `q`, and use bounded `limit` and
`offset` pagination. Attention items can be resolved through
`POST /v1/action` with `attention-acknowledge` or `attention-dismiss` and the
item's `attention_id`; the disposition is persisted and a changed attention
item receives a new ID.

AgentOS Home's System view reports whether the host is physical or virtualized
as a VPS, along with virtualization type and hostname. `agentosd` exposes the
typed settings catalog used by the shell, including native KDE entry points for
all system settings, Wi-Fi, Bluetooth, and mouse behavior. Those panels retain
Linux/Polkit authorization and remain the source of truth for hardware changes;
unavailable controls are reported as such on headless VPS hosts.

The package also installs AgentOS Help, the native Workspace desktop entry, and
offline documentation under `/usr/share/doc/agentos`. The native Qt/QML shell
includes Workspace, Agents, Activity, System, and a searchable command palette.
The AgentOS desktop session starts both surfaces.
Native Workspace is the default graphical surface.
Chromium Home keeps running underneath as the installed recovery fallback. Use
the AgentOS Home shortcut (Meta+H) to bring it forward; Meta+1 launches or
raises Native Workspace. Physical Wayland/Plasma behavior remains a separate
device-acceptance gate.
Over macOS/FreeRDP, use Ctrl+Alt+H and Ctrl+Alt+1..4 because macOS may consume
the non-modifier part of Command shortcuts before FreeRDP can forward it.

All `/v1` routes reject unsupported methods with `405 Method Not Allowed`, an
`Allow` header and a JSON error envelope. Client errors use
`{"error":{"code":"...","message":"..."}}`; successful response shapes
remain unchanged.

## Fresh install

For the provider-neutral VPS bootstrap and validation path, see
[VPS installation and onboarding](docs/vps-onboarding.md). The current
production-tested installation path below targets the physical Arch machine.

### Already-provisioned Arch VPS

The VPS installer is published with the stable signed repository, so the first
bootstrap needs no source checkout or compiler. Download the standalone script
and its checksum, verify it, and run the dry-run command first:

```bash
vps_tmp="$(mktemp -d)"
# The private-alpha release host; releases and issues require an invitation.
AGENTOS_RELEASE_BASE_URL='https://oleg-koval.github.io/agentos'
curl -fsSL "${AGENTOS_RELEASE_BASE_URL}/agentos-vps-install.sh" \
  -o "$vps_tmp/agentos-vps-install.sh"
curl -fsSL "${AGENTOS_RELEASE_BASE_URL}/agentos-vps-install.sh.sha256" \
  -o "$vps_tmp/agentos-vps-install.sh.sha256"
(cd "$vps_tmp" && sha256sum -c agentos-vps-install.sh.sha256)
chmod 700 "$vps_tmp/agentos-vps-install.sh"
sudo "$vps_tmp/agentos-vps-install.sh" \
  --repo-url "${AGENTOS_RELEASE_BASE_URL}/stable" \
  --repo-key-url "${AGENTOS_RELEASE_BASE_URL}/agentos-signing.asc" \
  --fingerprint EAC73D1D595C8F7D809D42EB268D28C12D93BC1B \
  --user "$USER"
sudo "$vps_tmp/agentos-vps-install.sh" \
  --repo-url "${AGENTOS_RELEASE_BASE_URL}/stable" \
  --repo-key-url "${AGENTOS_RELEASE_BASE_URL}/agentos-signing.asc" \
  --fingerprint EAC73D1D595C8F7D809D42EB268D28C12D93BC1B \
  --user "$USER" --yes
```

It verifies the published key before system writes, configures the signed
repository, installs `agentos-runtime` and `agentos-shell`, applies the
existing AgentOS service policy for the selected user, and runs onboarding.
Pass `--channel`, repeated `--project-root`, and `--agents` to write the
first-run desired configuration; the default role is `vps` and the default
agents are `claude,codex`. The signed release manifest also records the
bootstrap script checksum used by the release workflow.
Previous repository configuration is saved under `/var/lib/agentos/vps-installer`;
restore it with `sudo agentos-vps-install --reset` if needed.

### Declarative machine configuration

After the runtime package is installed, save the desired machine state as
`/etc/agentos/config.yaml` and inspect it without mutation:

The package also installs a complete template at
`/usr/share/agentos/config.yaml.example`; copy it to `/etc/agentos/config.yaml`
and edit paths and enabled capabilities for the target machine.

```yaml
version: 1
channel: stable
remote_access:
  ssh: true
  tailscale: true
  krdp: false
agents:
  claude: true
  codex: true
models:
  qwen-coder: true
project_roots:
  - /home/your-user/projects
backup:
  enabled: false
  schedule: quick
  target: /home/your-user/.config/agentos/hermes-backup-recipients.txt
power:
  sleep: disabled
  hibernate: disabled
```

If `/etc/agentos/config.yaml` is missing, run `sudo agentos config init` to
create a conservative baseline. Run `agentos config plan` to get a typed JSON diff, then
`agentos config apply` to validate the complete document and converge supported
changes. Fresh system-policy installs and runtime package upgrades create a
conservative baseline at this path without replacing an existing file; edit it
to enable agents, models, remote access, project roots, or backups. SSH and
Tailscale are protected access invariants; a mismatch is reported for manual
recovery rather than disabled automatically. Project roots
must already exist, and enabling backups requires a non-empty recipient file.
The applied version and content hash are recorded in
`/var/lib/agentos/config-state.json`.

### 1. Build the USB on macOS

```bash
./make-usb.sh
```

### 2. Boot the target from USB

Use UEFI mode and connect networking.

### 3. Install

```bash
export AGENTOS_SOURCE_URL='https://your-agentos-source-host.example/agentos.git'
git clone "$AGENTOS_SOURCE_URL" agentos
cd agentos
sudo ./install.sh
```

The interactive installer presents arrow-key menus for optional tools, the
target disk, and the erase confirmation. The default local account is `agent`.
You must deliberately select the erase action, confirm LUKS formatting, and
enter an encryption passphrase and a separate Linux login password.

Optional developer tools can be selected interactively at install time, or
provided explicitly as flags. The selection is saved for first-boot
convergence and remains disabled when omitted:

```bash
sudo ./install.sh --opencode --ide vscode
# IDE values: none, cursor, vscode, webstorm
```

With plain `sudo ./install.sh`, use the arrow keys and Enter to choose the
optional tools and target disk. The installer uses the `agent` account by
default and shows a final erase confirmation before changing the disk.

OpenCode is installed with its official user-scoped installer. VS Code uses
the signed Arch package; Cursor and WebStorm require an existing `paru` or
`yay` helper. Only one IDE value is accepted.

### 4. First boot

Run one explicit convergence command as the workstation user:

```bash
sync-workstation
```

It pulls current `main`, installs missing packages, refreshes policy/scripts and
dotfiles, and explicitly updates the OS and managed developer/agent tooling.

Optional account/service setup then happens separately:

```bash
sudo tailscale up
hermes setup
enable-hermes-gateway
```

Optional OpenCode and IDE selection can also be changed after installation:

```bash
sync-workstation --opencode --ide vscode
# IDE values: cursor, vscode, webstorm, none
```

OpenCode is installed in the user's XDG bin directory using its official
installer. VS Code uses Arch's signed `code` package; Cursor and WebStorm use
an already-installed `paru` or `yay` AUR helper. A normal `sync-workstation`
does not install or remove any of these optional tools.

## Ongoing convergence

The normal maintenance command is:

```bash
sync-workstation
```

Run it as the workstation user, not root. It:

1. authenticates GitHub when required and fast-forwards the managed checkout
2. installs the latest system policy before any package transaction
3. installs packages newly added to `packages.txt`
4. refreshes dotfiles
5. explicitly runs the Arch/tool updater
6. activates user backup timers

Managed checkout (new installs):

```text
~/.local/share/agentos/repo
```

Existing `~/.local/share/legacy-workstation` paths remain accepted as a
one-release migration alias. The checkout must be clean; sync refuses to
overwrite local changes.

For a machine installed before `sync-workstation` existed:

```bash
git pull
sudo install -m 755 sync-workstation.sh /usr/local/bin/sync-workstation
sync-workstation
```

## Update policy

The `stable` channel enables a guarded weekly update for Sunday at 06:00 with a
random delay of up to 30 minutes. The systemd service runs only on AC power.
`beta`, `edge`, and `none` skip the scheduled mutation. Beta is the published
candidate channel for supervised testing; edge is a build artifact until
promoted, and stable remains the default for friend installations. There is no
separate RC channel.

Before `pacman -Syu`, the update path checks the configured signed repository
and attempts to create the boot-consistent Btrfs recovery point described below.
It then runs the workstation doctor. When a recovery point was created, a failed
post-update check stages it for a one-shot rollback and a successful update arms
the next-boot health gate. Snapshot-creation failure does not currently abort
the update.

Inspect available package changes without mutation:

```bash
agentos update --check
```

The check verifies the active channel's signed release manifest and persists a
bounded per-user result. The guarded apply path persists its target version,
snapshot, migration outcome, success or failure, and whether a later manual
reboot is required. It never reboots automatically.

Desktop users can run the same flow from **System → Update Center**. The Plasma
status indicator and deduplicated notifications open that view; `Update now`
still launches the guarded command with normal authorization and a visible
terminal transcript.

Run the same guarded update path manually:

```bash
agentos update --apply
```

The separate weekly maintenance timer remains non-mutating. It runs
`workstation-maintenance-check`, includes the full workstation-doctor output,
and writes a readable report under:

```text
 /var/lib/agentos/maintenance/
```

View the latest report:

```bash
workstation-maintenance-check --show
```

`sync-workstation` remains the explicit full convergence path for source,
packages, policy, dotfiles, and managed developer tooling:

```bash
sync-workstation
```

The old `update-workstation.timer` is removed/disabled during convergence.

## Health checks and alerts

Run the consolidated health check manually:

```bash
sudo workstation-doctor
```

It checks the Btrfs root and device counters, disk usage, failed units, SSH,
Tailscale, Ollama, NVMe SMART, pacman snapshots, Hermes gateway state, Hermes
backup freshness, and Restic service health.

A daily timer runs the same health check automatically. When actionable failures
exist, `workstation-alert` attempts to send the report through Hermes. The
default target is:

```text
telegram
```

Override it by putting a Hermes send target in:

```text
~/.config/agentos/alert-target
```

For example:

```bash
printf '%s\n' 'telegram' > ~/.config/agentos/alert-target
```

Identical alerts are suppressed for 24 hours. If Hermes is not configured yet,
alerts safely no-op instead of breaking the health service.

Use `agentos welcome` after first login for the short command summary. Support
reports are generated locally with `agentos support`; telemetry is disabled by
default and queues only anonymous reliability events on the host. Uploads are
manual and require an explicitly configured HTTPS endpoint.

## Btrfs snapshots and boot-consistent rollback

Every pacman install/upgrade/remove creates two matching recovery artifacts
**before** the transaction:

1. a read-only Btrfs root snapshot under `/.snapshots/pre-pacman-*`
2. a matching copy of the systemd-boot entry, kernel and initrd files under
   `/.snapshots/boot/pre-pacman-*`

Keeping the `/boot` bundle with the root snapshot avoids the classic rollback
failure where an older `/usr/lib/modules` tree is paired with a newer kernel on
the EFI partition.

The post-transaction hook retains the newest 20 recovery points by default.

List recovery points:

```bash
sudo rollback-workstation list
```

Entries marked `boot-safe` have a valid matching boot bundle.

Stage a rollback:

```bash
sudo rollback-workstation stage pre-pacman-20260819-120000
```

Staging does **not** rewrite `arch.conf` or `arch-lts.conf`. Instead it:

- creates a writable `@rollback-*` root from the selected snapshot
- copies the matching old kernel/initrd bundle to `/boot/agentos-rollback/...`
- creates dedicated `agentos-rollback.conf` recovery entries
- runs `bootctl set-oneshot agentos-rollback.conf`

Only the **next boot** uses the rollback. If that boot fails, another reboot
returns to the normal entry automatically because the one-shot EFI variable has
already been consumed.

Check state:

```bash
sudo rollback-workstation status
```

Cancel a staged rollback before reboot:

```bash
sudo rollback-workstation cancel
```

Clean older writable rollback test subvolumes:

```bash
sudo rollback-workstation cleanup
```

The generated `/home/<user>/ops/recovery.md` also documents Arch-ISO/LUKS/chroot
recovery for cases where the installed system no longer boots.

## Hermes: migrate a complete Mac setup

Hermes' native backup/import mechanism is used instead of copying live database
files manually. A Hermes backup contains portable config, credentials, sessions,
memories, skills and profiles while excluding machine-specific runtime state.

On the source Mac:

```bash
hermes gateway stop
hermes backup
```

Copy the resulting zip to the AgentOS machine. `rsync` is installed by this repo, so
for example:

```bash
rsync -avP ~/hermes-backup-*.zip admin@agentos-host:~/
```

On the AgentOS machine:

```bash
migrate-hermes ~/hermes-backup-....zip
```

The migration helper:

- preserves another hard copy under `~/.local/share/hermes-backups/`
- stops any local gateway before import
- runs `hermes import --force`
- warns about `/Users/...` and `/opt/homebrew/...` paths that cannot be portable
- runs `hermes doctor`

After confirming the Mac gateway is stopped:

```bash
enable-hermes-gateway
```

Or explicitly request cutover during import:

```bash
migrate-hermes ~/hermes-backup-....zip --start
```

Do not leave two gateways polling the same Telegram bot token.

## Hermes always-on operation and encrypted backups

System policy creates a systemd linger marker for the workstation user, so the
user manager can run without a graphical login after reboot.

`enable-hermes-gateway` runs Hermes' gateway installer, enables/starts the
systemd user service and verifies the resulting status.

Portable Hermes backups are automated separately from Hermes' live state:

- daily quick backup at approximately 03:20
- weekly full backup on Sunday at approximately 04:10
- quick archives retained for 14 days
- full archives retained for 60 days

Archives live at:

```text
~/.local/share/hermes-backups/
```

They are encrypted with `age` and end in `.zip.age`. Plaintext ZIPs are created
only in the user's runtime temporary directory and removed after encryption.
Legacy plaintext `hermes-*.zip` files in the backup vault are encrypted on the
next successful backup run and then removed.

Recipient configuration lives at:

```text
~/.config/agentos/hermes-backup-recipients.txt
```

On first use, `hermes-backup` tries to seed this file from plain
`ssh-ed25519`/`ssh-rsa` lines in `~/.ssh/authorized_keys`. Otherwise create it
manually with one or more `age1...` recipients or supported SSH public keys.
**Keep the corresponding private recovery key somewhere other than this
machine.**

Manual backups:

```bash
hermes-backup --quick
hermes-backup --full
```

To restore one of these encrypted archives locally:

```bash
HERMES_BACKUP_AGE_IDENTITY=/path/to/private-key \
  migrate-hermes ~/.local/share/hermes-backups/hermes-full-....zip.age
```

Because the Restic scaffold backs up `/home`, the encrypted Hermes archives are
included automatically once Restic is configured.

## Agent browser

Agent browser state is isolated from your personal browser profile:

```text
~/.local/share/agent-browser
```

Playwright CLI is configured to use Arch's system Chromium rather than download
a foreign distro browser build.

From the local Plasma session:

```bash
agent-browser https://example.com --headed
```

From SSH/headless automation, omit `--headed`.

## Restic

Create `/etc/restic-backup.env` from the generated example and provide the
password file, then:

```bash
sudo systemctl enable --now restic-backup.timer
```

Retention is currently 7 daily, 4 weekly and 6 monthly snapshots.

A monthly `restic-verify.timer` runs `restic check` and then restores the latest
snapshot's `/etc/hostname` into a temporary directory. This catches both
repository-integrity failures and basic restore-path failures. It safely no-ops
until `/etc/restic-backup.env` exists.

Run the same verification manually:

```bash
sudo restic-verify
```

## CI

GitHub Actions runs validation on pushes to `main` and pull requests in an Arch
Linux container. It checks:

- `bash -n` for all managed scripts
- ShellCheck errors
- required policy assets
- duplicate package-manifest entries
- that every package in `packages.txt` exists in current Arch repositories
- mocked rollback staging, including proof that normal boot entries are untouched
- encrypted Hermes backup behavior, including absence of plaintext backup ZIPs

Local equivalent:

```bash
bash tests/static.sh
bash tests/integration.sh
```

## Verification

```bash
for f in \
  make-usb.sh install.sh bootstrap.sh apply-system-policy.sh sync-workstation.sh \
  update-workstation.sh install-dotfiles.sh install-agent-tools.sh maintenance-check.sh \
  workstation-doctor.sh workstation-alert.sh btrfs-pre-pacman-snapshot.sh \
  btrfs-prune-snapshots.sh rollback-workstation.sh hermes-backup.sh \
  migrate-hermes.sh enable-hermes-gateway.sh restic-verify.sh; do
  bash -n "$f"
done
```

Optional:

```bash
shellcheck *.sh
```

## Defaults

Common installer overrides:

```text
DISK=/dev/your-target-disk
HOSTNAME=agentos
USERNAME=your-user
TIMEZONE=UTC
LOCALE=en_US.UTF-8
SSH_PUBLIC_KEY='ssh-ed25519 ...'
```

## Remaining hardening

The major remaining boot-chain hardening is **Secure Boot** with `sbctl` and
signed boot artifacts. It is intentionally not auto-enabled because key
enrollment changes firmware trust state and should be an explicit operation.

## License

AgentOS Workstation is available under the [MIT License](LICENSE).
