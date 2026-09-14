# AgentOS agent guidance

This file is for Codex, Claude, Hermes, and other agents operating in an
AgentOS Linux checkout or on an AgentOS host. Keep work safe, observable, and
portable across physical machines and VPS installations.

## Understand the host first

AgentOS runs on Arch Linux. `agentosd` is the local runtime/state/action
boundary; AgentOS Home is the graphical shell; SSH is the preferred diagnostic
path. Tailscale and KRDP are optional remote-access layers. Do not assume that
a capability, agent, model, GUI session, or project is installed.

AgentOS Home keeps the native workspace and Chromium fallback as separate
surfaces. Preserve the fallback, the localhost API on `127.0.0.1:4787`, and
browser/Python IPC when changing the shell. Native display, resize, keyboard,
mouse, and lifecycle behavior require device or FreeRDP evidence; source tests
and API health checks cannot prove them.

Discover commands and installed capabilities before using them:

```bash
command -v agentos pacman systemctl ssh
agentos help
agentos store list
agentos plan
```

For normal read-only discovery, use:

```bash
agentos health
agentos state
agentos sessions
agentos hardware --json
agentos repository status
agentos update --check
agentos config plan
systemctl --failed --no-pager
systemctl --user --failed --no-pager
```

For ordinary AgentOS work, `agentos project open NAME` selects a project and
`agentos agent start codex|claude|hermes|herdr` starts an enabled agent. Check
`agentos store list` and `agentos plan` first; an agent or capability may not be
installed.

Use `pacman` for Arch packages. Search with `pacman -Ss NAME`, inspect an
installed package with `pacman -Q NAME`, and use `pacman -S --needed NAME` only
after the operator has approved the package change. Use AgentOS capabilities
through `agentos store` when they are provided there. Read installed
operational workflows under `/usr/share/agentos/skills` when that directory is
present.

The normal convergence path is `sync-workstation`. It fetches the configured
AgentOS source, creates a pre-change snapshot, applies packages and policy,
and validates remote-access invariants before arming the boot-health gate.
`AGENTOS_REPO` must be set for a new checkout unless `/etc/agentos/repository-url`
or an existing checkout remote provides it; never invent a repository owner.

## Diagnose remotely and safely

When working from another computer, connect to the target host over SSH and
run diagnostics there. Confirm the target before interpreting results:

```bash
ssh HOST
whoami
hostname
curl -fsS http://127.0.0.1:4787/v1/healthz
```

The AgentOS API is intended to remain localhost-only; do not expose port 4787.
For service failures, collect the smallest relevant output from
`systemctl status` or `journalctl` and preserve SSH access while investigating.

Before a package transaction, use `sudo rollback-workstation list` and select a
`boot-safe` snapshot when recovery is needed. Staging changes only the next
boot; it does not rewrite the normal boot entries. Verify the staged state and
leave the normal entry untouched unless the operator explicitly requests a
rollback.

Treat these as potentially mutating and ask the operator first: `sudo`,
package installation or updates, `agentos config apply`, service
start/stop/restart/enable, rollback or boot changes, firewall/network changes,
reboot, and any external write such as pushing code, opening an issue, or
uploading diagnostics. Run `sudo agentos config init` only with explicit
authorization and when `/etc/agentos/config.yaml` is missing. `agentos config
plan` and `agentos update --check` are inspection commands; apply their results
only with explicit authorization.

## Keep evidence honest

Separate evidence by scope:

- source inspection and local tests prove repository behavior;
- CI proves the provider-run checks for a commit;
- a signed package proves what was built and published;
- live SSH/API/systemd output proves the current host state;
- FreeRDP or direct user interaction proves physical GUI behavior.

Do not present API, CI, or source evidence as proof of physical display,
keyboard, mouse, resize, or lifecycle behavior. Record exact commands, exit
codes, versions, commit IDs, and the first meaningful error line.

## Privacy and reporting

Use read-only commands and temporary files under `/tmp` for diagnostics. Never
put passwords, private keys, access tokens, cookies, environment files, raw
agent prompts, proprietary task text, document contents, or unredacted personal
paths in commands, logs, issues, pull requests, or support bundles. Redact
hostnames, usernames, IP addresses, and unrelated output when they are not
needed to reproduce the problem.

When reporting a problem, include the command, expected and actual behavior,
AgentOS version, OS/architecture, host role (physical or VPS), safe diagnostic
output, and whether it began before or after an update or reboot. State what
was not tested instead of inferring it.

For a local report, use `agentos support`; review it before sharing. Reliability
telemetry is disabled by default and can be inspected with `agentos telemetry
status`. Enable it only with explicit user consent. Configure an upload endpoint
and run `agentos telemetry upload` only after separately approving that external
data transfer.

## Review findings

When asked to review code or a pull request, treat review and implementation as one task by default. Inspect the relevant code and requirements, verify each finding against the codebase, and implement every valid actionable finding directly in the working tree. Add or update focused tests when appropriate, run the relevant verification, and re-read the final diff.

Do not leave a review comment for a finding that you fixed. Leave a comment only when the finding is ambiguous, requires a product or architecture decision, or cannot be safely verified. Do not hand implementation off to another agent when the fix can be completed in the current task.
