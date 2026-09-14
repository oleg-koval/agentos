# Capability Map: AgentOS friend system experience

## Objective

Give a supervised private-alpha user one understandable system experience for
updates, migrations, hardware readiness, and recovery without replacing the
existing signed repository, Go operations boundary, QML workspace, Btrfs boot
recovery, or Chromium fallback.

Approved on 2026-09-06. Baseline implementation planning uses `origin/main` at
`f7efc4e385c52591960e3ba5499a6ec2604ca30c` (merged PR #79).

## Modules

| Module id | Responsibility | Depends on |
|---|---|---|
| `maintenance-operation-contract` | Stable read models and guarded action routing for maintenance UI | — |
| `versioned-migrations` | Ordered, idempotent system/user migrations with durable completion state | `maintenance-operation-contract` |
| `release-channel-contract` | Stable/beta/edge semantics, signed release metadata, and publication truth | `maintenance-operation-contract` |
| `update-center` | Update availability, notifications, one obvious update action, and visible result | `maintenance-operation-contract`, `versioned-migrations`, `release-channel-contract` |
| `hardware-readiness` | Read-only hardware/firmware status and separately authorized firmware actions | `maintenance-operation-contract` |
| `recovery-center` | Snapshot/rollback visibility plus guarded stage and cancel actions | `maintenance-operation-contract` |
| `desktop-cohesion` | One coherent System surface and first-run guidance across the native shell and fallback | `update-center`, `hardware-readiness`, `recovery-center` |

Build order:

```text
maintenance-operation-contract
  -> versioned-migrations + release-channel-contract
  -> update-center
  -> hardware-readiness + recovery-center
  -> desktop-cohesion
  -> VM/device QA
  -> one-friend stable canary
```

## Shared boundaries

- Extend `agentos-ops`, packaged `agentosd2`, `/v1/state`, `/v1/action`, and the
  current QML shell; do not add a second daemon or state store.
- Keep the daemon unprivileged and the API bound to `127.0.0.1:4787`.
- Run privileged work only through visible, explicit authorization. Firmware,
  rollback staging, service changes, and reboot remain separate actions.
- Keep channels `stable`, `beta`, `edge`, and `none`. Beta is the release
  candidate channel; no additional RC channel is introduced.
- Keep Chromium Home installed and reachable until native physical-device QA
  and a separately approved removal decision.
- Source/CI, signed artifacts, live-host state, reboot/rollback, graphical QA,
  and friend acceptance remain separate evidence layers.

## Product references

- Omarchy update, notification, channel, firmware, and rollback UX:
  https://github.com/omacom/omarchy/blob/quattro/manual/30-updates.md
- Omarchy ordered/idempotent migration model:
  https://github.com/omacom/omarchy/blob/quattro/agents/skills/migrations.md
- Omarchy snapshot UX:
  https://github.com/omacom/omarchy/blob/quattro/manual/47-system-snapshots.md
- fwupd command and JSON-output contract:
  https://fwupd.github.io/libfwupdplugin/fwupdmgr.html
- Qt `ApplicationWindow` used by the current native shell:
  https://doc.qt.io/qt-6/qml-qtquick-controls-applicationwindow.html
