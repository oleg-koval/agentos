# Capability Map: AgentOS Autonomous Skills

## Objective

Give agents a small, reusable operating model for the installed AgentOS Linux
workstation. The skills must teach agents how to inspect and operate the host
using the existing AgentOS CLI, systemd units, signed package workflow, and
recovery tools. They must not turn a prompt into implicit authorization for
privileged or destructive actions.

## Modules

| Module id | Responsibility | Depends on |
|---|---|---|
| `agentos-operator` | Safe daily operation: discover state, inspect health, work with projects/agents/sessions, operate the native shell, and report evidence | — |
| `agentos-maintainer` | Controlled updates, configuration, service recovery, signed-package verification, snapshots, and rollback | `agentos-operator` |
| `agentos-skill-distribution` | Install one canonical skill set and expose it to Codex, Claude Code, and Hermes without overwriting user skills | `agentos-operator`, `agentos-maintainer` |

Build order: `agentos-operator` → `agentos-maintainer` →
`agentos-skill-distribution`.

## Shared contract

- Skills use the Agent Skills `SKILL.md` format and remain instruction-first.
- Every workflow starts with discovery and separates source, CI/package, live
  host, and device/human evidence.
- `agentos-operator` may use read-only or explicitly user-requested reversible
  actions; it never assumes `sudo`, reboot, rollback, or broad cleanup.
- `agentos-maintainer` requires an explicit maintenance intent and preserves
  remote access, snapshots, package signatures, and the Chromium Home fallback.
- Distribution has one canonical source tree, idempotent adapters, and no
  mutation of existing user-owned skills.

## Gate

This map and build order must be approved before implementation begins. Each
module receives its own specification and acceptance tests in dependency order.
