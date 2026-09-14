# Community beta acceptance

Status: preparation in progress; this candidate is not accepted for public
installation. Existing QA is historical. No performance or superiority claim
against another distribution has been measured for this candidate.

The scope is x86_64 workstation use by developers running several coding
agents. VPS compatibility stays supported; new architectures and integrations
are deferred. Start with a small cohort after acceptance, fix repeated setup
friction, and expand only when new testers can complete a task independently.

## Candidate record

Record source commit, package versions and hashes, ISO filename/checksum,
signature verification, build and promotion run IDs, hardware/VM configuration,
commands with exit codes, first failure, screenshots, and skipped checks.
Keep raw diagnostics private and review screenshots for personal information.

## Required journeys on VM and spare PC

Use the exact signed candidate on both targets. The operator must identify and
approve each target and the spare disk before erasure. Record disk model,
capacity, and stable identifier; do not infer approval from a device name.

| Journey | Required evidence | Current candidate |
| --- | --- | --- |
| Download and boot | Anonymous download, checksum/signature verification, USB/UEFI boot | Not run |
| Install | Guided choices, deliberate erase confirmation, encrypted disk install | Not run |
| Installed boot | Remove installer media, reboot, unlock, log in to native desktop | Not run |
| First task | Select a project, install/enable an agent, authenticate, complete a real task | Not run |
| Multiple sessions | Two projects and agents, switch/focus, terminate/reopen sessions | Not run |
| Failure guidance | Missing optional agent/credentials, unavailable provider, daemon disconnect | Not run |
| Desktop | Keyboard, pointer, focus, resize, native lifecycle, Chromium Home recovery | Not run |
| Update and recovery | Signed update, invalid signature, interrupted download, boot-safe rollback and normal return | Not run |

Keep the localhost API at `127.0.0.1:4787` and browser/Python IPC compatible.
Use the [system acceptance runbook](friend-system-acceptance.md) for recovery
checks on disposable installations. API health cannot prove GUI behavior.

After login, begin with `agentos store list` and `agentos plan`; installed
capabilities and provider credentials are not assumed. Use `agentos project
open NAME` and `agentos agent start codex|claude|hermes|herdr` for an enabled
agent. Follow its provider authentication flow locally; never include secrets
or raw prompts in reports. If setup fails, use [help](help.md) and
[troubleshooting](troubleshooting.md), and record the actual guidance shown.

## Publication gate

Require passing source/CI/package/migration/signature/channel/site checks,
exact-head Codex review with zero unresolved Codex threads, verified merge,
and both accepted install/task/recovery journeys. Zero known data-loss or
security blockers and zero broken core journeys are required. List lesser
limitations in the public release. Publish tested signed bytes unchanged.

Audit a fresh source export, preserve licenses, and establish public build,
signing, download, bug-report, and contribution paths before redirecting the
landing page. Add real desktop screenshots and a short recorded task demo
from the accepted candidate. Do not substitute mockups for evidence.

For comparisons with Omarchy, evaluate installation, first useful agent task,
desktop usability, update/recovery, resource usage, documentation, and
customization. Separate documented features from measurements. Performance
comparisons require comparable hardware and workloads; no superiority claim
is currently supported.

## Announcement draft (not posted)

AgentOS is opening a small x86_64 community beta for developers who run multiple
coding agents. It brings agent sessions and workstation operations into a
native desktop, with a Chromium fallback and boot-safe recovery tools.

Use the installation guide and supported-hardware/known-limitations record
published with the accepted release. Please try one real project task and
report where installation, authentication, session switching, or recovery was
unclear. Review local support reports before sharing them. Contributions and
reproducible bug reports are welcome through the public repository.

Release links, screenshots, demo, measured support, and known limitations must
be filled from accepted evidence before this draft is approved for posting.
