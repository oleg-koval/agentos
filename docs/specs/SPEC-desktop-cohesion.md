# Spec: `desktop-cohesion`

## Objective

Turn the existing native Workspace into a coherent friend-facing system
experience by integrating Update Center, Hardware Readiness, Recovery Center,
first-run guidance, and status notifications. Chromium Home remains an installed
recovery fallback.

## Tech stack

- Qt 6 `ApplicationWindow`, Qt Quick Controls, and QML `XMLHttpRequest`
- Existing KWin activation shortcuts and Plasma integration
- Packaged `agentosd2` localhost API
- Existing Chromium Home fallback

Qt reference:
https://doc.qt.io/qt-6/qml-qtquick-controls-applicationwindow.html

## Commands

```bash
bash tests/static.sh
cd core && go test ./cmd/agentosd2
bash repository/build-repo.sh
bash tests/package-content.sh out/repo/x86_64
git diff --check
```

## Project structure

- `agentos/native-shell/Main.qml` remains the primary desktop surface.
- `agentos/theme/` owns shared visual tokens/assets.
- `agentos/kwin/` owns activation and fallback shortcuts.
- `agentos-home.sh` remains a reduced recovery-compatible client.
- ADR-001 records the current native-default/fallback decision after evidence is
  reconciled.

## Code style

Use small reusable QML controls with semantic state properties:

```qml
StatusCard {
    title: "Updates"
    state: root.field(root.snapshot.updates, "status", "unknown")
}
```

Keep business rules and command construction out of QML. Respect keyboard-only
navigation, focus visibility, reduced motion, and no-color status text.

## Testing strategy

- Static-test required views/actions and package ownership.
- Unit-test API contracts in Go; avoid screenshot snapshots for business state.
- Run offscreen QML startup checks where supported.
- Verify real click, keyboard, resize, scaling, notification, shortcut, service
  lifecycle, and fallback behavior on VM and physical Plasma sessions.

## Boundaries

- Always: one System information architecture; meaningful text alongside color;
  usable keyboard focus; preserve QML/API separation and Chromium fallback.
- Ask first: remove fallback, change default shell/service behavior, add a UI
  framework, or change global shortcuts.
- Never: duplicate update/recovery logic in QML, hide privileged boundaries,
  claim visual acceptance from static tests, or remove fallback during this plan.

## Success criteria

- A first-time friend can locate updates, hardware readiness, recovery, support,
  and active channel without using the terminal.
- Status indicators and notifications open the relevant System section.
- Native and fallback clients consume the same state semantics.
- ADR-001, README, autostart behavior, and package tests agree on the native
  default and fallback contract.
- VM and physical GUI acceptance cover display, scaling, click, keyboard,
  Mac/FreeRDP mappings, lifecycle, and fallback restoration.

## Open questions

No shell replacement is in scope. Removal of browser IPC or Chromium Home is a
later, separately approved decision after physical acceptance.
