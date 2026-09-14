# AgentOS implementation roadmap

AgentOS is an Arch-based AI workstation. The product boundary sits above Linux: projects, agents, sessions, models, observability, updates and recovery. Commodity infrastructure stays upstream unless replacing it creates measurable value.

## Definition of v0.1

AgentOS v0.1 is ready when a second machine can be installed reproducibly, updated without GitHub access, recovered after a failed update, and used primarily through the AgentOS shell without understanding the underlying Arch/Plasma implementation.

## P0 — reliability and protected remote access

Goal: `sync-workstation` and system updates become recoverable transactions.

- [x] Btrfs pre-package snapshots and matching boot bundles
- [x] SSH + Tailscale + KRDP remote access
- [x] workstation health checks
- [x] transactional sync generation record
- [x] preflight checks before convergence
- [x] post-apply validation gate
- [x] treat SSH/Tailscale and configured KRDP as protected invariants
- [x] record GOOD/FAILED generations
- [x] automatically stage a one-shot recovery boot when convergence validation fails
- [x] integration test the convergence failure path
- [x] boot-time health gate for the next boot of a converged generation
- [x] automatic one-shot rollback when a candidate boot cannot become healthy
- [x] rollback-loop protection with a single automatic attempt
- [x] preserve the armed recovery snapshot from normal pruning
- [x] mocked integration tests for healthy boot, failed boot, rollback and loop protection
- [x] VM test the complete candidate-boot failure and rollback path with real systemd-boot/Btrfs

Exit criteria: a failed convergence cannot silently leave the machine in an unknown state. A successfully converged generation is armed for next-boot validation; failure stages and boots the pre-change snapshot once, while loop protection prevents reboot storms. The complete candidate failure and rollback path has been validated in an x86_64 KVM guest with real systemd-boot and Btrfs.

## P1 — authoritative agent runtime

Goal: agents become first-class runtime objects instead of inferred processes.

- [x] `agentosd` canonical state/action daemon
- [x] project and Git state
- [x] process-level Claude/Codex/Hermes/Herdr discovery as fallback
- [x] initial PR/CI state
- [x] typed Session / Task / ToolCall / Artifact / Event foundation
- [x] typed lifecycle states: STARTING/RUNNING/THINKING/TOOL/WAITING/BLOCKED/BACKGROUND/DONE/FAILED
- [x] persistent JSONL event store across daemon restart
- [x] persistent session registry across daemon restart
- [x] event-backed sessions even when no Linux PID is discoverable
- [x] event ingestion API for agent adapters/hooks
- [x] Herdr semantic-state bridge for supported agents
- [x] process reconciliation with terminal DONE transition after a tracked PID exits
- [x] tool-call and artifact association on persistent sessions
- [x] attention inbox for agent/system/CI attention
- [x] attach / stop / logs / diff / PR actions in the runtime API
- [x] deduplicated attention items
- [x] first-class Agent identity/config object separate from runtime Session
- [x] direct/native hook enrichment for Claude Code, Codex, Hermes and Herdr tool/approval events
- [x] file-change events with structured before/after metadata
- [x] indexed log history beyond the persistent event stream
- [x] explicit acknowledgement/dismissal semantics for resolved attention items

Exit criteria: the shell can answer what every agent is doing, what changed, and whether human input is required without guessing from Linux process state. Herdr provides the first authoritative semantic-state path and the runtime now preserves event-backed sessions independently of process discovery.

## P1 — real distribution and release pipeline

Goal: stable machines update only from signed AgentOS releases.

- [x] Arch package layouts for AgentOS components
- [x] stable/beta/edge channel metadata
- [x] repository builder
- [x] package signing key and trust bootstrap
- [x] hosted `agentos` pacman repository
- [x] CI-built binaries so Go is not required on stable machines
- [x] signed release manifest + checksums + release notes
- [x] edge on successful main, beta by promotion, stable weekly by promotion
- [x] remove GitHub checkout/authentication from stable update path
- [x] release integration tests in a clean VM

The edge push, explicit edge-to-beta promotion, and scheduled beta-to-stable
promotion chain is verified remotely, including signed artifact lineage and
stable publication. Manual and scheduled workflow paths both record
schedule/source evidence in the run summary.

Exit criteria: `agentos update` on stable does not use GitHub and installs only signed, tested artifacts.

## P1 — accessible installation and onboarding

Goal: a technically capable non-expert can install AgentOS on a private VPS,
secure it, and understand the first useful actions without reading the source
checkout or knowing Arch administration.

- [x] supported VPS installation profile for a small set of documented providers
- [ ] guided install/bootstrap using signed AgentOS artifacts, SSH keys and an explicit firewall policy
- [x] first-run onboarding for machine role, update channel, remote access, projects and enabled agents
- [x] onboarding validation that confirms SSH, Tailscale when selected, AgentOS Home and the local API
- [x] safe recovery path and uninstall/reset documentation for VPS users
- [x] `agentos help` and desktop Help surface linked to versioned, plain-language documentation
- [x] troubleshooting guides for installation, remote access, updates and rollback
- [x] clean-VPS reproducibility test with no GitHub login, Go compiler or source checkout required

The first release should optimize for one reliable path from a fresh VPS to a
working private AgentOS machine. The signed bootstrap now records the selected
VPS role, channel, project roots and enabled agents in a complete first-run
configuration; the release manifest binds the bootstrap checksum to the signed
artifact lineage. Provider-specific automation must not weaken SSH, package
signature verification, Linux permissions or the local-only privileged API
boundary.

See [VPS installation and onboarding](docs/vps-onboarding.md).
See [VPS provider validation matrix](docs/vps-providers.md).

## P2 — provider-neutral onboarding hardening

Goal: turn the validated VPS path into a repeatable provider matrix without
weakening signed bootstrap, SSH, or recovery guarantees.

- [x] repeat-apply idempotence contract in the VPS installer test
- [x] document provider prerequisites and required disposable-host evidence
- [x] validate one disposable provider end to end
- [ ] validate a second disposable provider end to end
- [ ] automate provider-specific clean-host provisioning through small adapters
- [x] add a credential-free CI contract test for the shared provider contract
- [ ] add a credential-free CI contract test for every provider adapter

## P2 — declarative machine state

Goal: replace imperative convergence with desired-state management.

- [x] `/etc/agentos/config.yaml` schema and package-owned example
- [x] `agentos plan`
- [x] `agentos apply`
- [x] typed diff between desired and actual state
- [x] idempotent capability installers
- [x] migration/version semantics
- [x] reproducibility test on a clean machine

The clean-machine contract is covered by `tests/config.sh`: a fresh state
file is applied from a complete desired document and a second plan reports
`migration: none` with every change `satisfied`.

Desired state should cover update channel, remote access, agents, models, project roots, backup policy and power policy.

Exit criteria: a fresh AgentOS machine can converge from one declarative configuration file.

## P2 — reduce shell-script runtime

Goal: Bash remains bootstrap glue, not the product runtime.

Move stateful/policy logic into typed components when it parses structured data, retries, stores state or makes policy decisions.

- [x] update/release client in Go
- [x] recovery transaction manager in Go
- [x] remote-state validation in Go
- [x] capability registry/install logic in Go
- [x] configuration plan/apply engine in Go
- [x] retain small bootstrap/install shell scripts only

The stateful operations now live in the packaged `agentos-ops` Go binary.
Existing `agentos-*` scripts are compatibility shims; installer, USB, boot,
and other direct system-tool orchestration remains deliberately small shell
glue.

## P2 — native AgentOS shell

Goal: remove browser-specific behavior while preserving the current design and observability model.

Current:

```text
KWin -> Chromium -> localhost Python bridge -> agentosd
```

Target:

```text
KWin / Wayland -> native AgentOS Shell -> agentosd
```

Preferred first implementation: Qt/QML because Plasma already provides Qt, Wayland and DBus integration.

- [ ] stabilize agentosd API
- [x] initial `/v1` API version marker
- [x] native Workspace view
- [x] native Agents / Activity / System views
- [x] native command palette
- [x] KWin Meta+1 native Workspace launch/activation with Meta+H Chromium Home rollback
- [ ] KWin integration without browser IPC
- [ ] remove Chromium/Python shell bridge
- [ ] keep Chromium only as the agent/browser automation runtime

## P3 — AI workstation differentiators

Only after the reliability and distribution foundation is complete:

- [x] initial agent attention inbox
- [ ] automatic isolated worktree allocation
- [ ] resource scheduler for concurrent agents/models
- [ ] model router based on capability/cost/latency
- [ ] permission broker for sudo, GitHub writes and external actions
- [ ] full audit trail
- [ ] crash/reboot session recovery beyond state reconstruction
- [ ] remote handoff between desktop/phone/SSH
- [ ] first-class artifacts: diffs, PRs, screenshots, tests and generated files
- [ ] notification policy based on WAITING/BLOCKED/FAILED rather than generic activity

## Explicit non-goals

Do not build these without a clear technical reason:

- custom Linux kernel
- custom libc
- custom package manager
- custom bootloader
- custom filesystem
- generic app store
- custom terminal emulator
- custom editor
- custom network stack

## Execution order

1. Run the remaining P0 rollback flow in a clean VM and fix any real boot-order issues.
2. Build P1 signed repository and GitHub-independent stable updates.
3. Enrich native agent adapters with approvals, structured tool calls and file changes.
4. Implement P2 declarative `agentos plan/apply`.
5. Migrate stateful Bash into Go. (complete)
6. Build the native Qt/QML shell.
7. Add P3 orchestration and autonomy features.
