---
name: agentos-maintainer
description: Perform explicitly authorized AgentOS updates, configuration, service recovery, signed-package verification, snapshots, and rollback. Use only for maintenance; never infer permission to mutate or reboot.
---

# AgentOS maintainer

Use this skill only when the user explicitly requests AgentOS maintenance or
recovery. It is not a generic Linux administration guide and it does not grant
permission to mutate the workstation.

## Maintenance contract

- State the requested change, host, user, and recovery objective.
- Collect preflight evidence before the first mutation.
- Preserve SSH/Tailscale/KRDP access and the Chromium Home fallback.
- Verify signatures and package ownership; a local build is not deployment
  evidence.
- After every mutation, verify the live daemon, services, API, and package
  integrity separately.
- Never infer a reboot from a staged rollback.

## Preflight

Run the narrowest complete set for the requested operation:

```bash
command -v agentos agentos-config workstation-doctor rollback-workstation pacman gpg
agentos version
agentos health
agentos repository status
agentos update --check
agentos config plan
sudo workstation-doctor
sudo rollback-workstation list
sudo rollback-workstation status
systemctl --failed --no-pager
systemctl --user is-active agentosd.service agentos-home.service
```

Stop if remote access, repository/signature state, health, or recovery points
are unavailable. Report the exact blocker and do not apply a partial change.

## Authorized operations

Before each command, state its expected effect and confirm that the user has
authorized that class of mutation:

```bash
agentos config apply
agentos update --apply
sudo rollback-workstation stage <recovery-point>
sudo rollback-workstation cancel
```

Use the existing package/release verification workflow. Do not duplicate
signing or rollback logic in this skill. If a command is missing, stop instead
of substituting an unverified script.

## Verification

After an update or configuration change, collect at least:

```bash
agentos version
agentos health
agentos state
sudo pacman -Qkk agentos-runtime agentos-shell
systemctl --failed --no-pager
systemctl --user is-active agentosd.service agentos-home.service
```

For rollback work, verify `rollback-workstation status`, the selected recovery
point, normal boot entries, remote access, and the live API before describing a
reboot as safe. A staged rollback is only preparation.

## Stop conditions

Stop and report instead of proceeding when:

- a signature, manifest, package owner, or recovery point cannot be verified;
- the host loses required remote access or has failed health units;
- the requested operation would delete unknown paths or user-owned skills;
- the user has not explicitly authorized `sudo`, service restart, rollback, or
  reboot;
- evidence is available only from source or CI, not from the live host.

Never bypass signature checks, use broad `/usr/local` cleanup, force a reboot,
or remove Chromium Home while native shell work is being validated.

## Completion report

Report the request, preflight, exact mutations, verification commands and
outputs, recovery state, and remaining risk. Keep source, package/CI, live-host,
and device/human acceptance evidence in separate sections. Use `NOT_VERIFIED`
when a required evidence layer was not collected.
