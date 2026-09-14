# ADR-001: Additive native Workspace in Qt/QML

## Status

Accepted. Native Workspace is the default graphical surface.
Chromium Home remains installed as the recovery fallback.

## Decision

Implement the native AgentOS shell as a QML `ApplicationWindow`
launched by the packaged `qt6-declarative` runtime. The view reads the existing
localhost `agentosd` `/v1/state` endpoint and uses the typed agent, session,
event, health, update, system/settings, model, and developer-tool data already
exposed by that API. It is installed as an explicit desktop entry while the
AgentOS desktop session starts it as the default surface. Chromium Home starts
underneath it and remains reachable as the recovery fallback.

Qt Quick Controls provide the top-level window and controls, and QML's
`XMLHttpRequest` provides the small read-only HTTP client needed for the
localhost API. See the official Qt documentation for
[ApplicationWindow](https://doc.qt.io/qt-6/qml-qtquick-controls-applicationwindow.html),
[Qt Quick Controls](https://doc.qt.io/qt-6/qtquickcontrols-index.html), and
[XMLHttpRequest](https://doc.qt.io/qt-6.8/qml-qtqml-xmlhttprequest.html).

## Consequences

- The native view shares one authoritative state source with Home and CLI.
- Agents, activity, and system views are read from the same authoritative state
  source; explicit actions continue through the existing `/v1/action` boundary.
- Privileged settings remain KDE/Polkit actions owned by the existing API.
- The package carries both native and Chromium clients. This keeps the current
  shell recoverable while physical Wayland/Plasma acceptance remains a separate
  evidence gate.
- KWin owns native Workspace launch/activation on Meta+1 while Meta+H remains
  the Chromium Home rollback path. Ctrl+Alt+1..4 and Ctrl+Alt+H provide the
  same shell paths over macOS/FreeRDP, where Command shortcuts can be consumed
  locally. Removal of the Chromium shell bridge remains a later rollout step
  and does not change the daemon contract.

## Rejected for this slice

- Removing Chromium autostart or its fallback shortcut.
- Adding a second state store or bypassing `agentosd` with filesystem reads.
- Implementing hardware controls in QML instead of delegating to KDE/Polkit.
