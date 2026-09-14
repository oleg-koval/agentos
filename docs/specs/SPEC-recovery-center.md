# Spec: `recovery-center`

## Objective

Expose the existing Btrfs/systemd-boot recovery state in a user-friendly System
view. Users can inspect snapshots and staged rollback, then explicitly stage or
cancel a one-shot rollback. Reboot and cleanup remain separate operations.

## Tech stack

- Existing `rollback-workstation` and `agentos-boot-health` mechanisms
- Go 1.23 normalization in `agentos-ops`/`agentosd2`
- Qt 6 QML and Chromium fallback
- Btrfs snapshots plus matching boot bundles and systemd-boot one-shot entries

Product comparison:
https://github.com/omacom/omarchy/blob/quattro/manual/47-system-snapshots.md

## Commands

```bash
cd core && go test ./cmd/agentos-ops ./cmd/agentosd2 -run Recovery
bash tests/boot-health.sh
bash tests/transaction.sh
bash tests/static.sh
git diff --check
```

## Project structure

- `rollback-workstation.sh` remains the low-level stage/cancel/list mechanism.
- `agentos-ops` owns validation and structured recovery output.
- `agentosd2` exposes read state and allow-listed visible actions.
- `agentos/native-shell/Main.qml` owns the primary Recovery Center.

## Code style

Model recovery safety explicitly:

```go
type RecoveryPoint struct {
	ID       string `json:"id"`
	BootSafe bool   `json:"boot_safe"`
	Created  string `json:"created,omitempty"`
}
```

Only opaque validated IDs cross the UI boundary. Paths and shell fragments do
not.

## Testing strategy

- Unit-test empty, root-only, boot-safe, staged, current-rollback, and malformed
  state.
- Stub low-level commands and assert stage/cancel argument validation.
- Preserve existing boot-health loop-prevention and normal-entry tests.
- Prove boot and return-to-normal behavior first in a disposable VM and then on
  approved physical hardware; source/API checks are insufficient.

## Boundaries

- Always: read before mutation; allow staging only `boot-safe` points; explain
  one-shot behavior; preserve normal boot entries and remote access.
- Ask first: stage/cancel rollback, reboot, delete a snapshot, or alter retention.
- Never: combine stage with reboot, expose arbitrary snapshot paths, stage a
  root-only snapshot, delete recovery points in the first UI version, or claim
  rollback from source/CI evidence.

## Success criteria

- The UI shows current root, available points, `boot-safe` versus `root-only`,
  staged source, and next-boot behavior.
- Stage and cancel launch exact guarded commands with confirmation and display
  the refreshed result.
- Reboot is a separate action with a second explicit decision.
- Existing automatic failure staging and boot-health behavior remain unchanged.
- VM and physical rollback evidence is recorded separately.

## Open questions

Snapshot deletion/retention management is intentionally deferred until the
read-only and stage/cancel experience has physical acceptance evidence.
