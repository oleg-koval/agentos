# AgentOS

AgentOS is the product layer built from this repository: an Arch-based persistent AI-agent workstation with safe updates, remote access, agent runtimes, recovery and a purpose-built observability shell.

## Current architecture

- Arch Linux as upstream distribution and package ecosystem
- LUKS2 + TPM2 recovery path + Btrfs + systemd-boot
- KDE Plasma/KWin underneath AgentOS for Wayland, device integration and remote desktop
- i3 retained as a lightweight fallback session
- `agentosd` as the typed runtime/state/action boundary
- AgentOS Home as the single graphical shell surface
- KWin-native AgentOS shortcuts that raise Home and dispatch commands into it
- Kitty + Herdr for persistent interactive agent work
- Claude Code, Codex, Hermes, Ollama and Playwright/browser automation
- SSH + Tailscale + KRDP for remote/mobile access
- pre-pacman Btrfs snapshots, recovery tooling and workstation health checks
- weekly stable update channel

The architecture deliberately keeps commodity operating-system responsibilities in proven upstream components. AgentOS owns the AI-workstation contract: projects, agents, models, sessions, activity, health, updates and recovery.

```text
KWin / Wayland
      |
      +-- AgentOS Home
              |
              +-- agentosd
                    +-- projects / git
                    +-- agent sessions
                    +-- models / resources
                    +-- system health
                    +-- update/recovery actions
                    +-- remote state
```

AgentOS Home is intentionally a thin client. It should not independently scrape operating-system state or own process lifecycle logic.

## Upgrade an existing machine into AgentOS

```bash
sync-workstation
```

Verify:

```bash
agentos-desktop --status
agentos state
agentos health
```

Enable the graphical login/AgentOS experience:

```bash
agentos-desktop --enable
sudo reboot
```

i3 remains installed as a fallback session. SSH/Tailscale access is independent of the GUI.

## Shell workflow

AgentOS Home has four operational views:

- **Workspace**: selected repository, Git state and live agent work
- **Agents**: running sessions, launch controls, loaded models and resource attribution
- **Activity**: AgentOS runtime events and recent commits
- **System**: health, services, update state and recovery controls

Primary shortcuts:

```text
Meta/Super + K     command palette
F8                 command palette fallback for RDP clients that drop Meta
Meta/Super + H     Home / Workspace
Meta/Super + 1     Workspace
Meta/Super + 2     Agents
Meta/Super + 3     Activity
Meta/Super + 4     System
Meta/Super + Enter Terminal
```

The KWin integration activates/raises the existing Home window before dispatching shell navigation. It does not start duplicate AgentOS launcher/control windows.

## Remote desktop from macOS

Use FreeRDP SDL rather than Microsoft Windows App. The latter has shown transport/keyboard issues with KRDP in this setup.

Install FreeRDP:

```bash
brew install freerdp
```

Install the helper from this repository into your Mac user bin directory:

```bash
mkdir -p ~/.local/bin
install -m 755 clients/macos/agentos-rdp ~/.local/bin/agentos-rdp
```

Default connection:

```bash
agentos-rdp
```

The helper connects to the host selected with `AGENTOS_RDP_HOST` or `--host`, uses the selected AgentOS user, keeps the remote desktop at `1920x1080`, and uses FreeRDP smart sizing to scale it to a Retina display.

Useful overrides:

```bash
agentos-rdp --windowed
agentos-rdp --native
agentos-rdp --host agentos.example --user admin
agentos-rdp --windowed --responsive
AGENTOS_RDP_SIZE=2560x1440 agentos-rdp
```

Persistent defaults can be set in the Mac shell profile:

```bash
export AGENTOS_RDP_HOST=agentos.example
export AGENTOS_RDP_USER=admin
export AGENTOS_RDP_SIZE=1920x1080
```

## Build the installer ISO

The supported friend-release path is the signed ISO workflow. It builds the
ISO only after the exact signed AgentOS repository has passed verification.
Run the manual release workflow on `main` with `channel=edge` and
`build_iso=true`, then download the immutable ISO artifact and verify its
checksum and signature before sharing it.

For a local Arch builder, provide a verified signed AgentOS repository:

```bash
AGENTOS_SOURCE_REV="$(git rev-parse HEAD)" \
AGENTOS_CHANNEL=beta \
AGENTOS_REPO=https://github.com/oleg-koval/agentos.git \
AGENTOS_SIGNED_REPO_DIR=/path/to/verified/beta/x86_64 ./build-agentos-iso.sh
```

The builder starts from Arch's maintained `releng` profile, embeds an exact
local repository for the base-system dependency closure plus the signed
AgentOS repository, applies AgentOS policy/assets, and emits a SHA-256
checksum beside the image. The installed system uses the embedded packages;
network access is needed only to configure the persistent HTTPS update channel
and for later updates.

```text
out/agentos-*.iso
out/agentos-*.iso.sha256
```

Boot the ISO and run:

```bash
cd /root/agentos
./install.sh
```

After first boot:

```bash
sync-workstation
```

## Product boundaries

AgentOS should not fork or reinvent mature Linux infrastructure without a measurable reason. In particular, avoid building a custom kernel, libc, package manager, bootloader, filesystem, terminal emulator, editor or generic app store.

The differentiated layer is one step above Linux:

```text
Linux / Arch / systemd / Wayland / pacman
-----------------------------------------
AgentOS projects / agents / models / sessions
AgentOS observability / automation / recovery
```

## Next architecture milestones

1. Move more remaining runtime shell-script logic behind typed AgentOS components.
2. Add structured agent lifecycle events such as waiting, tool use, file changes and completion.
3. Add first-class PR/CI state to project/workspace state.
4. Add richer model/GPU telemetry.
5. Introduce declarative machine state with `agentos apply`.
6. Deploy the signed AgentOS package repository for stable machines.
7. Complete transactional updates with health-gated rollback.
8. Replace the Chromium prototype shell with a native Qt/QML or Rust client after the `agentosd` API is stable.

## Release principle

Keep the base OS conservative, keep agent tooling independently updateable, and make every stable update recoverable. A Claude/Codex/Hermes release should not require rebuilding the entire distribution.
