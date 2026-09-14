# Spec: `update-center`

## Objective

Give desktop users one obvious place to see update availability, understand the
active channel, launch the existing guarded update, and see its last outcome.
Stable scheduled updates remain enabled; no update path reboots automatically.

## Tech stack

- Go 1.23 update policy in `agentos-ops` and state in packaged `agentosd2`
- Existing systemd stable update timer
- Qt 6 QML native System view, Plasma status widget, and Chromium fallback
- Signed static channel metadata from `release-channel-contract`

Product reference:
https://github.com/omacom/omarchy/blob/quattro/manual/30-updates.md

## Commands

```bash
cd core && go test ./cmd/agentos-ops ./cmd/agentosd2 -run Update
bash tests/update-gate.sh
bash tests/static.sh
bash tests/package-content.sh out/repo/x86_64
git diff --check
```

## Project structure

- `core/cmd/agentos-ops/` owns check/apply policy and durable result records.
- `core/cmd/agentosd2/` exposes update state and allow-listed launch actions.
- `agentos/native-shell/Main.qml` owns the primary Update Center.
- The Plasma widget and Chromium Home expose a reduced compatible view.

## Code style

Expose semantic state rather than presentation strings:

```go
type UpdateState struct {
	Status         string `json:"status"`
	CurrentVersion string `json:"current_version"`
	TargetVersion  string `json:"target_version,omitempty"`
	RebootRequired bool   `json:"reboot_required"`
}
```

## Testing strategy

- Unit-test no-update, available, check-failed, apply-failed, successful, and
  reboot-required states.
- Stub pacman/repository/snapshot/migration/doctor commands and assert ordering.
- Verify one notification per release/result, with acknowledgement persistence.
- Run QML/static/package checks, then verify click/visual behavior on a VM and
  physical Plasma session.

## Boundaries

- Always: verify repository first; snapshot before package mutation when
  available; run system migrations; run doctor; record bounded result; retain
  manual reboot.
- Ask first: change the weekly stable timer, block all direct pacman use, or add
  in-process privileged execution.
- Never: bypass signatures, auto-update beta/edge, claim success when only a
  terminal was launched, or reboot automatically.

## Success criteria

- The System view and status area clearly distinguish up-to-date, available,
  checking, failed, and reboot-required conditions.
- One `Update now` action launches `agentos update --apply` through explicit
  authorization and the existing recovery path.
- Notifications are deduplicated by release/result and link to Update Center.
- Last check, last successful update, last failure summary, snapshot ID, and
  migration outcome survive daemon restart.
- Stable scheduled updates and manual updates use the same core ordering.

## Open questions

None for the first release. Rich in-window progress is deferred; the initial
implementation may use the visible terminal transcript plus durable result.
