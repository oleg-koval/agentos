# Spec: `agentos-maintainer`

## Objective

Create a controlled maintenance skill for an AgentOS workstation. It teaches
an agent how to plan and verify signed updates, configuration convergence,
service recovery, and boot-consistent rollback while preserving remote access,
recoverability, and the distinction between package evidence and live/device
acceptance.

## Tech Stack

- Agent Skills `SKILL.md` format
- `agentos` and `agentos-config` CLI surfaces
- pacman and the signed AgentOS repository
- systemd, Btrfs snapshots, boot-health, and rollback helpers already shipped
  by `agentos-runtime`
- GnuPG package and release-manifest verification

## Commands

The skill must verify command availability and current host state before any
mutation.

```bash
command -v agentos agentos-config workstation-doctor rollback-workstation pacman gpg
agentos version
agentos channel
agentos health
agentos repository status
agentos update --check
agentos config plan
sudo workstation-doctor
sudo rollback-workstation list
sudo rollback-workstation status
sudo pacman -Qkk agentos-runtime agentos-shell
systemctl --failed --no-pager
systemctl --user is-active agentosd.service agentos-home.service
```

Only after explicit authorization, a complete preflight, and a recorded
rollback path may the skill use:

```bash
agentos config apply
agentos update --apply
sudo rollback-workstation stage <recovery-point>
sudo rollback-workstation cancel
```

The skill must not infer a reboot from staging a rollback. A reboot is a
separate user-authorized operation with remote-access and recovery checks.

## Project Structure

```text
.agents/skills/agentos-maintainer/
└── SKILL.md                           # Canonical maintenance instructions
docs/specs/SPEC-agentos-maintainer.md # This specification
tests/skills/                            # Safety and workflow fixtures
```

## Code Style

Maintenance instructions are organized as preflight → authorization →
mutation → verification → handoff. Each mutation names its evidence and
rollback condition.

```markdown
## Update gate

Collect `agentos health`, `agentos repository status`, `agentos update --check`,
and `rollback-workstation list`. If remote access, signatures, or recovery
points are not healthy, stop and report the blocker. Do not apply the update.
```

Use exact commands, explicit stop conditions, and no broad shell globs. Keep
package ownership and live runtime checks separate.

## Testing Strategy

1. Validate frontmatter and the skill folder with the repository’s skill
   validator.
2. Add fixtures for signed update planning, configuration plan/apply, service
   recovery, and rollback staging/cancellation.
3. Add negative fixtures proving that missing signatures, unhealthy remote
   access, absent recovery points, or an unapproved reboot stop the workflow.
4. Run mocked rollback/configuration integration coverage and repository static
   checks.
5. On a disposable or explicitly approved workstation, verify package
   signatures, `pacman -Qkk`, service health, API behavior, and recovery status
   after a maintenance run.

## Boundaries

- Always: preflight health, remote access, repository/signature state, and
  recovery points; use the packaged `agentosd2` runtime; verify after every
  mutation; retain Chromium Home as fallback.
- Ask first: `sudo`, package updates, config apply, service restarts,
  rollback staging, reboot, channel changes, or edits to user-owned agent
  configuration.
- Never: bypass signature checks, force-push or overwrite user skills, delete
  unknown paths, perform broad `/usr/local` cleanup, or claim deployment from
  a local build alone.

## Success Criteria

- The skill only triggers for AgentOS maintenance and recovery work.
- Every mutating path has explicit authorization, preflight, verification, and
  a stop condition.
- Signed package/repository evidence, live service/API evidence, and
  device/human acceptance are reported separately.
- Rollback instructions preserve normal boot entries and remote access.
- Safety, negative, mocked integration, static, and approved live checks pass.

## Open Questions

- Define the exact release-manifest evidence fields in the implementation
  spec after the current repository promotion scripts are reviewed. Do not
  duplicate signing logic in the skill.
