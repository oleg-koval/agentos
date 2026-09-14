---
name: agentos-operator
description: Operate an installed AgentOS Linux workstation for project, agent, session, shell, and health tasks. Do not use for package updates, rollback, reboot, or privileged maintenance.
---

# AgentOS operator

Use the installed AgentOS interfaces to inspect and operate the workstation.
Do not turn this skill into a generic Linux administration guide. Prefer the
AgentOS CLI and report evidence from the current host.

## Operating contract

- Inspect before acting. State the host, user, project, and current request.
- Use commands that are installed on this host; if one is missing, report it
  instead of substituting an unverified implementation.
- Keep source, package/CI, live-host, and device/human evidence separate.
- Treat empty, unavailable, and failed as different states.
- Preserve SSH/Tailscale/KRDP access and the Chromium Home fallback.
- Ask before starting or stopping a service, creating an agent session, or
  changing a project or user setting.

## First response

Run the smallest read-only discovery set that answers the request:

```bash
command -v agentos
agentos version
agentos state
agentos health
agentos boot-status
systemctl --user is-active agentosd.service agentos-home.service
```

When the question concerns the shell or a stuck view, add:

```bash
systemctl --user status agentos-home.service agentos-native-workspace.service --no-pager
systemctl --failed --no-pager
```

When the question concerns an agent or project, add:

```bash
agentos sessions
agentos repository status
```

Use `git status --short --branch` and `git rev-parse --show-toplevel` only
when the request is tied to a checkout.

## Ordinary actions

After inspection and confirmation of the target, use the narrowest existing
AgentOS action:

```bash
agentos project open <name>
agentos agent start <claude|codex|hermes|herdr> [project]
```

If an action changes a session, service, setting, or project selection, state
the exact command and expected effect before running it. Verify the resulting
state with `agentos state`, `agentos sessions`, or the relevant service status.

## Local API fallback

Use the documented loopback AgentOS API only when the CLI does not expose the
needed read. Query it read-only at the configured local daemon endpoint (the
default is `http://127.0.0.1:4787`). Do not create a second state store, scrape
client internals, or use an arbitrary remote endpoint.

## Escalation boundary

Stop and report the evidence collected when the request requires any of the
following:

- `sudo`, package installation or update, repository/channel changes
- `agentos config apply`, service restart, reboot, or rollback
- snapshot deletion, broad cleanup, or edits outside the requested project
- browser-IPC removal, release promotion, or device-level acceptance

Do not run those actions from this skill. Explain that they require the
maintenance workflow and explicit authorization, naming the exact next action
and the missing evidence.

## Completion report

End with a compact report containing:

1. Request and target host/project.
2. Commands actually run and the important outputs.
3. Current state: healthy, empty, unavailable, or failed.
4. Any action taken and its verification.
5. The next escalation, if the request is outside this skill.

Never claim that a local command, package build, or API response proves device
or human acceptance. If the host cannot provide evidence, say `NOT_VERIFIED`.
