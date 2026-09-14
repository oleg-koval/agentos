# AgentOS distribution model

AgentOS is an Arch-derived persistent AI workstation distribution. Arch is the upstream package ecosystem; AgentOS owns the workstation contract, release channels, shell, agent runtime, remote access, recovery policy, and capability registry.

## Release channels

- `stable`: weekly tested release. Automatic update Sunday around 06:00 local time. No automatic reboot.
- `beta`: promoted builds. Manual update.
- `edge`: every successful main build. Manual update.

Use:

```bash
agentos version
agentos channel
agentos channel stable
agentos update --check
agentos update --apply
agentos rollback
```

Every update creates a Btrfs pre-update snapshot when available and runs `workstation-doctor` afterward. Failed post-update health does not delete the snapshot, so `agentos rollback` remains available.

## Package repository

`repository/build-repo.sh` builds packages under `packages/agentos-*` and creates a normal pacman repository database with `repo-add`. Set `AGENTOS_SIGN_KEY` to sign packages and the repository database.

The intended production pacman configuration is:

```ini
[agentos]
SigLevel = Required
Server = https://packages.agentos.dev/$arch
```

Until that endpoint is deployed, the source repository remains the canonical update source for AgentOS policy and shell code.

## Capability registry

`registry/capabilities.json` is the machine-readable AgentOS Store catalog. The first CLI surface is:

```bash
agentos store list
agentos store install browser
agentos store install docker
agentos store install qwen-coder
```

The Store is deliberately agent-workflow focused rather than a replacement for KDE Discover.

## Packaging roadmap

1. `agentos-base`: tested dependency metapackage.
2. `agentos-runtime`: CLI, policy, systemd units, health and recovery.
3. `agentos-shell`: AgentOS Home, launcher, control center and Plasma integration.
4. `agentos-agent-runtime`: Herdr/Hermes/agent integration contract.
5. Signed binary repository and release ISO promotion from CI.

Do not fork the Arch kernel or core repositories unless AgentOS develops a concrete requirement that cannot be solved by configuration or packages.
