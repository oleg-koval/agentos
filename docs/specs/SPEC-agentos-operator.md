# Spec: `agentos-operator`

## Objective

Create a focused skill that lets an agent use an installed AgentOS workstation
autonomously for ordinary work without requiring a generic Linux tutorial. It
must teach the agent to discover the current host, inspect AgentOS state and
health, work with projects/agents/sessions, operate the default native shell
while preserving Chromium Home as the recovery fallback, and stop at a clear
escalation boundary when maintenance or privilege is needed.

## Tech Stack

- Agent Skills `SKILL.md` format
- AgentOS CLI: `agentos`
- AgentOS runtime API at the existing local daemon endpoint
- systemd user services and standard read-only diagnostics
- Bash commands already shipped by this repository

## Commands

The skill must use the installed command when available and report a missing
command rather than substituting an unverified implementation.

```bash
command -v agentos
agentos version
agentos state
agentos health
agentos sessions
agentos boot-status
agentos repository status
systemctl --user is-active agentosd.service agentos-home.service
systemctl --user status agentos-home.service agentos-native-workspace.service --no-pager
systemctl --failed --no-pager
agentos project open <name>
agentos agent start <claude|codex|hermes|herdr> [project]
```

When the CLI output is insufficient, the skill may inspect the documented
loopback API read-only. It must not invent another state source.

## Project Structure

```text
.agents/skills/agentos-operator/
└── SKILL.md                         # Canonical operator instructions
docs/specs/SPEC-agentos-operator.md # This specification
tests/skills/                          # Trigger and behavior fixtures
```

The initial skill should be self-contained. Add `references/` only when a
maintained procedure is too large for the entrypoint.

## Code Style

The entrypoint is imperative, explicit, and short. It teaches ordering and
decision points rather than restating Linux manuals.

```markdown
## First response

1. Run `command -v agentos` and `agentos version`.
2. Run `agentos state`, `agentos health`, and `agentos boot-status`.
3. Report observed state and missing evidence before taking an action.

Do not run `sudo`, reboot, rollback, package installation, or broad cleanup
from this skill. Escalate to `agentos-maintainer` with the exact requested
change and the evidence already collected.
```

Use lowercase kebab-case names, fenced copy-pasteable commands, and explicit
expected evidence. Never hide a write inside a command described as diagnosis.

## Testing Strategy

1. Validate frontmatter and the skill folder with the repository’s skill
   validator once the skill exists.
2. Add prompt fixtures that must trigger the skill for “AgentOS is unhealthy,”
   “open my project,” and “why is the native shell not visible.”
3. Add negative fixtures for generic Linux questions, package upgrades,
   rollback, reboot, and destructive cleanup.
4. Run the operator workflow against a live workstation in read-only mode and
   record command output plus service/API evidence.
5. Run repository static validation and `git diff --check`.

Success is behavioral: the agent chooses the existing CLI, reports evidence,
and escalates instead of guessing or mutating privileged state.

## Boundaries

- Always: inspect first; use existing AgentOS commands; preserve remote access;
  distinguish empty, unavailable, and failed state; report exact commands and
  outputs used.
- Ask first: starting/stopping services, creating an agent session, changing
  configuration, selecting an update channel, or any action outside the
  current project/session.
- Never: run `sudo`, reboot, stage/cancel rollback, install packages, delete
  snapshots, remove browser IPC, or broadly clean `/usr/local`.

## Success Criteria

- The skill triggers for ordinary AgentOS workstation operation and does not
  claim generic Linux administration coverage.
- Its first diagnostic path uses `agentos version`, `state`, `health`, and
  `boot-status` plus relevant user-service status.
- It can explain project, agent, session, native-shell, and remote-access
  state using existing interfaces.
- It never grants itself privileged authority and clearly hands maintenance
  work to `agentos-maintainer`.
- Trigger, negative, static, and live read-only checks pass.

## Open Questions

- Which agent host should own the cross-skill handoff wording when more than
  one skill is available? Resolve this in the distribution specification; it
  must not change the operator safety boundary.
