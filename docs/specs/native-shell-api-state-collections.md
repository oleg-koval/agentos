# Spec: Stable `/v1/state` collection shapes

## Objective

Keep the AgentOS v1 state response safe for native QML and Chromium Home when a
documented collection is empty. Collections in this slice must encode as JSON
arrays (`[]`), never `null`.

This is the first narrow API-stabilization slice. It does not redesign session
persistence, actions, or browser IPC.

## Tech stack

- Go `net/http` and `encoding/json` in `core/cmd/agentosd2`
- Qt/QML and Chromium JavaScript clients consuming `/v1/state`
- Go tests using `testing` and `net/http/httptest`

## Commands

```bash
cd core && go test ./cmd/agentosd2 -run 'TestStateCollectionsEncodeAsArrays'
cd core && go test ./...
bash tests/static.sh
git diff --check
```

## Project structure

- `core/cmd/agentosd2/main.go` — installed runtime API and state producers
- `core/cmd/agentosd2/main_test.go` — focused JSON contract coverage
- `agentos/native-shell/Main.qml` — native consumer
- `agentos-home.sh` — Chromium consumer

## Code style

Use explicit, typed collection initialization at the API boundary:

```go
if state.Models == nil {
	state.Models = []Model{}
}
```

Do not add reflection, a new serialization layer, or client-only null guards as
the primary fix. The server owns its public response shape.

## Testing strategy

1. Add a focused failing test that JSON-encodes an otherwise empty state,
   including a non-Git project, and asserts every in-scope collection is an
   array.
2. Make the smallest server-side change that satisfies that contract.
3. Run the full Go suite and repository static validation.
4. Verify the installed daemon returns arrays for empty live collections before
   marking the roadmap item complete.

## Boundaries

- Always: preserve existing field names and non-empty values; keep `/v1` error
  and method behavior unchanged; test the encoded JSON shape.
- Ask first: add or remove fields, change action semantics, change persisted
  schema, or introduce a dependency.
- Never: fix this only in QML/Chromium, change the legacy
  `core/cmd/agentosd` implementation instead of the packaged `agentosd2`, or
  begin browser-IPC removal in this slice.

## Success criteria

- Top-level `projects`, `agents`, `sessions`, `attention`, `resources`,
  `models`, `developer_tools`, and `events` encode as arrays when empty.
- Every `projects[].commits` value encodes as an array, including for a plain
  directory that is not a Git repository.
- Nested `health.alerts` and `system.settings` encode as arrays when empty.
- Existing non-empty state values are unchanged.
- Focused and full Go tests, static validation, package build, and installed
  runtime verification pass.
- The native shell and Chromium Home keep using the same v1 response without
  client-specific compatibility branches.

## Deferred contract work

- `sessions[].artifacts`, `sessions[].approvals`, and
  `sessions[].changed_files` remain optional because they currently use
  `omitempty` and neither shipped client consumes them. Stabilizing their
  presence semantics should be a separately reviewed API slice when a client
  needs them.
- Action validation/status taxonomy, response write failures, and browser IPC
  removal are separate slices. They are not coupled to collection encoding.
