# Spec: `maintenance-operation-contract`

## Objective

Provide one backward-compatible contract through which native QML, Chromium
Home, and the CLI can inspect maintenance state and launch guarded maintenance
actions. The first version uses visible terminal/Polkit authorization for
mutations; it does not add an asynchronous job service.

## Tech stack

- Go 1.23 standard library in `core/cmd/agentos-ops` and packaged `agentosd2`
- JSON over the existing localhost `/v1/state` and `/v1/action` API
- Qt 6 QML and the existing Chromium Home client

## Commands

```bash
cd core && go test ./cmd/agentos-ops ./cmd/agentosd2
cd core && go test ./...
bash tests/static.sh
git diff --check
```

## Project structure

- `core/cmd/agentos-ops/` owns validation, ordering, JSON read models, and CLI
  behavior.
- `core/cmd/agentosd2/` exposes the packaged localhost state/action boundary.
- `agentos/native-shell/Main.qml` and `agentos-home.sh` consume that boundary.
- `docs/decisions/ADR-002-typed-operations-in-go.md` remains authoritative.

## Code style

Use explicit typed values at the API boundary:

```go
type MaintenanceAction struct {
	ID             string `json:"id"`
	Available      bool   `json:"available"`
	RequiresAuth   bool   `json:"requires_auth"`
	RequiresReboot bool   `json:"requires_reboot"`
}
```

Keep validation in Go and shell files as compatibility shims. Do not make QML
parse command output or inspect privileged files.

## Testing strategy

- Unit-test JSON shapes, invalid action payloads, and unavailable commands.
- Contract-test that old `/v1/state` fields and current action names remain
  compatible.
- Stub launched commands and assert exact arguments without invoking `sudo`.
- Verify the packaged daemon on a target host before calling the contract live.

## Boundaries

- Always: bind localhost only; validate action IDs/parameters; redact command
  errors returned to clients; expose explicit unavailable/unsupported states.
- Ask first: add dependencies, change `/v1` fields incompatibly, or replace the
  visible-terminal authorization path.
- Never: run the daemon as root, accept arbitrary commands, expose port 4787,
  or treat a launched command as successful completion.

## Success criteria

- Update, migration, hardware, and recovery read models have stable JSON shapes.
- Every maintenance mutation maps to an allow-listed `agentos-ops` command.
- A client can distinguish unavailable, ready, running/launched, succeeded,
  failed, and reboot-required states without parsing human text.
- Existing CLI, QML, and Chromium flows continue to work.
- Focused/full Go tests, static checks, package tests, and installed API checks
  pass at their appropriate evidence layers.

## Open questions

None for the first slice. In-app background job progress is deferred until a
visible-terminal launch proves insufficient in real use.
