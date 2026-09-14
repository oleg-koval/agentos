# AgentOS VPS installation and onboarding

AgentOS should be usable by people who want a private AI workstation but do
not want to assemble an Arch system manually. The first supported remote
scenario is a small private VPS administered over SSH, with optional Tailscale
and AgentOS Home access.

## User journey

```text
fresh VPS
  -> verify provider and SSH access
  -> install signed AgentOS bootstrap
  -> choose machine role, channel, remote-access policy, projects and agents
  -> validate the machine
  -> open AgentOS Home or `agentos help`
  -> start a project or agent
```

The normal path must not require a Git checkout, GitHub authentication, a Go
compiler, or manual editing of several system files.

## Bootstrap an already-provisioned Arch VPS

This path assumes a provider has already created an x86_64 Arch Linux VPS and
that an existing non-root user can log in over SSH. The provider must provide
networking, an active `sshd` listener on TCP 22, and normal pacman access. The
bootstrap does not install an operating system, partition or format disks,
open ports, alter `sshd`, disable a firewall, or reboot the host.

The installer and checksum are published alongside the stable repository, so
this first step needs no source checkout or Go compiler. Download and verify
the standalone script, then review its dry-run plan before rerunning with
`--yes`:

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
  --user "$USER" --role vps --channel stable \
  --project-root "$HOME/src" --agents claude,codex

sudo "$vps_tmp/agentos-vps-install.sh" \
  --repo-url "${AGENTOS_RELEASE_BASE_URL}/stable" \
  --repo-key-url "${AGENTOS_RELEASE_BASE_URL}/agentos-signing.asc" \
  --fingerprint EAC73D1D595C8F7D809D42EB268D28C12D93BC1B \
  --user "$USER" --role vps --channel stable \
  --project-root "$HOME/src" --agents claude,codex --yes
```

The command imports and locally trusts the exact published key, writes one
managed signed-repository Include, installs `agentos-runtime` and
`agentos-shell`, enables the existing AgentOS system/user policy, writes the
first-run machine configuration, and runs `agentos-onboarding --local`. The
configuration records the `vps` role, update channel, SSH/Tailscale/KRDP
policy, selected agents, and project roots. Project roots must be absolute
paths below the selected user's home; new directories are created as that user.
Use `--agents ''` when no agent integrations should be enabled yet. The
installer passes each selected agent to the packaged, user-scoped installer;
if an optional tool is unavailable, core AgentOS setup still completes and the
output includes a resumable command. It is idempotent; rerun the same command after a disconnect. On a headless VPS, the
API and core user services are required; AgentOS Home is skipped until a
Wayland session exists. Optional `--tailscale` and `--krdp` make those final
checks required. Do not omit the fingerprint or replace it with a key that
merely downloads successfully.

Before mutable changes, the installer stores the existing pacman configuration,
repository Include, repository state, and first-run configuration in
`/var/lib/agentos/vps-installer/backup-*`. Restore the newest saved
configuration and remove installer-created metadata with:

```bash
sudo agentos-vps-install --reset
```

Reset leaves installed packages and imported key trust in place. It is not a
package rollback; use the provider snapshot or pacman's normal recovery path
for a failed package transaction. This workflow never assumes Btrfs and never
creates or deletes disks.

## Read-only onboarding validation

After the signed AgentOS packages are installed, validate a VPS from the
operator machine:

```bash
./agentos-onboarding.sh admin@vps.example
```

The command keeps the normal OpenSSH host-key and authentication policy. It
opens an SSH session, asks for the normal remote `sudo` authentication if
needed, and streams the same script to the VPS in local validation mode. The
remote checks are read-only: they inspect `sshd`, the signed repository state,
installed AgentOS package versions, the AgentOS local API, and the AgentOS Home
user service when a graphical session is available. On a headless VPS it reports
Home as optional and skipped. No package transaction, repository repair, service restart,
firewall change, or access-policy change is performed. `sudo -v` only refreshes
the normal sudo credential timestamp for the session.

Require the optional remote-access checks explicitly when they are part of the
machine's intended role:

```bash
./agentos-onboarding.sh --tailscale --krdp admin@vps.example
```

Expected output is a line-oriented report like:

```text
[OK]   SSH reachability      connected and running remote validation
[OK]   Signed repository      configured, trusted, and reachable (...)
[OK]   AgentOS packages       installed: agentos-runtime ...;agentos-shell ...
[OK]   AgentOS local API      http://127.0.0.1:4787/v1/healthz is healthy
[SKIP] AgentOS Home           no Wayland session; graphical Home is optional on a headless VPS
[SKIP] Tailscale              not requested; no Tailscale state was changed
[SKIP] KRDP                   not requested; no graphical-access state was changed

Onboarding validation passed.
```

Use the package-installed command when the validator is already on the VPS:

```bash
ssh -tt admin@vps.example 'sudo -v && agentos-onboarding --local'
ssh -tt admin@vps.example 'sudo -v && agentos-onboarding --local --tailscale --krdp'
```

The command is stateless and idempotent. If the connection drops, rerun the
same invocation. There is no onboarding marker to reset and no cleanup action
is required. A failed repository check means the validator did not repair it;
inspect it with:

```bash
ssh -tt admin@vps.example 'sudo -v && sudo agentos-repository status'
```

Then apply the documented signed-repository configure/repair procedure and
rerun validation. For service failures, inspect without changing state first:

```bash
ssh -tt admin@vps.example 'systemctl --user status agentosd.service agentos-home.service'
ssh -tt admin@vps.example 'journalctl --user -u agentosd.service -u agentos-home.service -n 100 --no-pager'
```

SSH or provider-console recovery remains operator-controlled; the validator
never changes firewall rules, SSH configuration, Tailscale enrollment, or KRDP
configuration.

The validator requires an Arch/systemd host, the normal AgentOS command names,
and a sudo credential for repository/package inspection. Tailscale validation
checks the local daemon and IPv4 address, not reachability from every client.
KRDP validation checks the user service, not a completed graphical client
connection. A successful SSH check proves only the path from the machine that
ran the validator.

## Installation principles

- SSH keys are the initial access mechanism; passwords are not required by the
  AgentOS installer.
- Package signature verification remains mandatory and trusts the published
  AgentOS release key explicitly.
- `agentos-vps-install` must show the exact changes it will make before applying them.
- Firewall and exposed services must be explicit. The local agentosd API is not
  exposed directly to the Internet.
- The installer must save the prior pacman/repository configuration before
  mutable changes; provider snapshots remain optional and provider-controlled.
- Provider-specific code belongs in small adapters. The AgentOS runtime should
  remain provider-neutral.

## Guided first run

The non-interactive first-run flow asks only for decisions that materially
change the machine:

1. repository URL, published key URL, and exact key fingerprint
2. existing non-root service user and the fixed `vps` machine role
3. update channel, project roots, and enabled agent integrations
4. optional required Tailscale and KRDP validation

It then writes a complete desired configuration and displays a concise
validation report covering package trust, AgentOS daemon health, remote access,
the saved first-run configuration, and the next recommended action. Run
`agentos config plan` before enabling optional capabilities or backups.

## Documentation in the product

Documentation must be reachable from both environments:

- `agentos help` for SSH and terminal users
- AgentOS Home Help/Onboarding for graphical users
- versioned online documentation for installation and recovery
- concise offline troubleshooting for a machine with no Internet access

The desktop surface should link to actions and explanations, not duplicate the
entire manual. Privileged actions must still go through AgentOS's explicit
approval boundary and normal Linux permissions.

## Acceptance criteria

This track is complete for v0.1 when a clean supported VPS can be brought to a
healthy AgentOS state using the documented path, with:

- signed packages and repository trust verified
- no source checkout or compiler required after bootstrap
- SSH preserved throughout installation
- optional Tailscale and graphical access validated when selected
- repository configuration backup persisted and bootstrap resumable after disconnect
- `agentos health` and the desktop Help surface providing the same actionable
  diagnosis
- documented rollback and recovery steps tested on a disposable VPS or VM
