# Herdr on AgentOS

Herdr is the persistent terminal multiplexer used for interactive AI-agent work on this workstation.
Hermes remains the always-on messaging/autonomous agent; Herdr keeps interactive Claude, Codex,
Hermes and other terminal-agent sessions alive when SSH/Termius disconnects.

## Provisioning

`sync-workstation` converges Herdr through `install-agent-tools --update`.

The managed setup:

- installs the stable Linux binary with Herdr's official checksum-verifying installer into `~/.local/bin/herdr`
- does not replace the Herdr binary while a Herdr server is running, so an explicit workstation sync cannot kill or strand active panes during a protocol-changing release
- creates `~/.config/herdr/config.toml` with `onboarding = false` while preserving other user configuration
- installs the Claude Code and Codex integrations
- installs the Hermes integration whenever `~/.hermes` exists
- `migrate-hermes` and `enable-hermes-gateway` also install/update the Hermes integration, so a later Hermes migration/setup does not require another workstation sync
- generates zsh completion at `~/.zfunc/_herdr`
- uses the shared `~/worktrees` tree for agent worktrees by linking Herdr's default `~/.herdr/worktrees` path there

Run:

```bash
sync-workstation
herdr --version
herdr integration status
```

## Normal workflow

Canonical repositories live directly under `~/src`:

```bash
cd ~/src/promptctl
herdr
```

Herdr launches or attaches to the default persistent background session. Start agents inside its panes:

```bash
codex
claude
hermes
```

Parallel/temporary branches and agent worktrees belong under:

```text
~/worktrees/
```

See `PROJECTS.md` for the workstation's source-tree conventions.

Detach with the Herdr prefix (`Ctrl+B`, then `Q`) or simply close the SSH/Termius client. The Herdr
server and pane processes continue running. Run `herdr` again to reattach.

Useful commands:

```bash
herdr status
herdr integration status
herdr --session work
herdr server stop
```

`herdr server stop` ends the session and its pane processes, so do not use it merely to disconnect.

## Updates

The repository intentionally avoids replacing the Herdr executable when `herdr status server` reports
an active server. This protects long-running agent panes. A later `sync-workstation` run while no Herdr
server is active installs the latest stable binary.

Herdr config remains user-editable at:

```text
~/.config/herdr/config.toml
```

The workstation only manages the `onboarding = false` root setting; it does not overwrite themes,
keybindings, sidebar settings or other user choices.
