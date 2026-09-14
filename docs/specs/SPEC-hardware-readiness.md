# Spec: `hardware-readiness`

## Objective

Show whether a physical AgentOS host has the minimum observable hardware,
firmware, storage, display, and connectivity prerequisites. Firmware discovery
is read-only by default; enabling fwupd and applying firmware are distinct,
explicitly authorized actions.

## Tech stack

- Go 1.23 read model in `agentos-ops`/`agentosd2`
- Existing Linux interfaces and installed tools (`findmnt`, `bootctl`, `nmcli`)
- Optional `fwupd`/`fwupdmgr` integration using JSON output
- Qt 6 QML presentation

Official fwupd command contract:
https://fwupd.github.io/libfwupdplugin/fwupdmgr.html

## Commands

```bash
cd core && go test ./cmd/agentos-ops ./cmd/agentosd2 -run Hardware
bash tests/static.sh
bash tests/package-content.sh out/repo/x86_64
git diff --check
```

## Project structure

- `core/cmd/agentos-ops/` normalizes bounded readiness and firmware JSON.
- `core/cmd/agentosd2/` exposes non-sensitive state and action availability.
- `agentos/native-shell/Main.qml` displays readiness separately from health.
- `docs/help.md` documents unsupported, unavailable, and reboot-required states.

## Code style

Each check reports status and reason explicitly:

```go
type ReadinessCheck struct {
	ID     string `json:"id"`
	Status string `json:"status"`
	Detail string `json:"detail,omitempty"`
}
```

Use `ready`, `warning`, `blocked`, `unsupported`, and `unavailable`; absence of
a tool or vendor firmware must not be reported as a generic failure.

## Testing strategy

- Stub every external command and test malformed/partial fwupd JSON.
- Verify no read-only check installs packages, enables remotes, uploads reports,
  changes BIOS settings, updates firmware, or reboots.
- Verify firmware actions require explicit confirmation and surface reboot need.
- Perform real device discovery and firmware application as separate physical
  QA gates; discovery does not prove update success.

## Boundaries

- Always: preserve privacy; state unsupported/unavailable honestly; use fwupd
  JSON for parsing; keep firmware outside the normal package-update action.
- Ask first: install `fwupd`, enable a remote, apply firmware, change BIOS
  settings, upload device/history reports, or reboot.
- Never: use force/downgrade, disable TLS checks, auto-enable telemetry/reporting,
  apply firmware unattended, or equate LVFS absence with incompatible hardware.

## Success criteria

- Physical hosts show architecture, boot mode, root filesystem/recovery
  eligibility, connectivity, display/session basics, and firmware support state.
- `fwupdmgr get-devices --json`, `get-updates --json`, and
  `check-reboot-needed` are normalized when fwupd is available.
- A user can enable firmware support and launch updates only through separate
  confirmed actions.
- VPS hosts show a clear not-applicable subset rather than false failures.
- Unit/package checks and physical discovery QA pass separately.

## Open questions

None for the first release. `fwupd` is an on-demand capability: AgentOS must
report when it is absent and offer a separately authorized enablement path,
without adding it to the default package set.
