#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$repo_root"
scripts=(make-usb.sh install.sh build-agentos-iso.sh bootstrap.sh apply-system-policy.sh sync-workstation.sh setup-project-layout.sh cheatsheet.sh agentos-cli.sh agentos-native-workspace.sh agentos-onboarding.sh agentos-vps-install.sh agentos-power-policy.sh agentos-transaction.sh agentos-agent-event.sh agentos-native-event.sh agentos-herdr-bridge.sh agentos-boot-health.sh agentos-weekly-update.sh agentos-desktop.sh agentos-shell.sh agentos-home.sh agentos-ui.sh agentos-remote-desktop.sh agentos-encryption.sh update-workstation.sh install-dotfiles.sh install-agent-tools.sh maintenance-check.sh workstation-doctor.sh workstation-alert.sh agentos-support.sh agentos-telemetry.sh btrfs-pre-pacman-snapshot.sh btrfs-prune-snapshots.sh rollback-workstation.sh hermes-backup.sh migrate-hermes.sh enable-hermes-gateway.sh restic-verify.sh repository/build-repo.sh clients/macos/agentos-rdp tests/integration.sh tests/transaction.sh tests/native-event.sh tests/capabilities.sh tests/onboarding.sh tests/vps-install.sh tests/provider-contract.sh tests/config.sh tests/optional-tools.sh tests/agentos-skills.sh tests/support-telemetry.sh)
scripts+=(ensure-agentos-config.sh tests/config-init.sh)
scripts+=(tests/agent-tool-selection.sh)
scripts+=(agentos-migrate-notify.sh)
scripts+=(agentos-update-notify.sh tests/update-notify.sh)
for script in "${scripts[@]}";do [[ -f "$script" ]]||{ echo "Missing script: $script" >&2;exit 1;};bash -n "$script";done
if command -v shellcheck >/dev/null 2>&1;then shellcheck -S error "${scripts[@]}";fi
required_assets=(packages.txt AGENTS.md AGENTOS.md DISTRO.md ROADMAP.md config/agentos-config.example.yaml agentos-native-event.sh agentos-hermes-plugin/plugin.yaml agentos-hermes-plugin/__init__.py core/go.mod core/internal/hardware/contract.go core/internal/hardware/contract_test.go core/internal/maintenance/contract.go core/internal/updatestate/contract.go core/cmd/agentos-ops/main.go core/cmd/agentos-ops/hardware.go core/cmd/agentos-ops/hardware_test.go core/cmd/agentos-ops/migrations.go core/cmd/agentos-ops/updates.go core/cmd/agentosd/main.go core/cmd/agentosd2/main.go core/cmd/agentosd2/main_test.go core/cmd/agentos-config/main.go core/cmd/agentos-config/main_test.go systemd/user/agentosd.service systemd/user/agentos-herdr-bridge.service systemd/user/agentos-home.service systemd/user/agentos-native-workspace.service systemd/user/agentos-ui@.service release/channels/stable.json release/channels/beta.json release/channels/edge.json registry/capabilities.json migrations/system/20260906-001-remove-legacy-wallpaper.sh migrations/system/20260906-002-clear-legacy-health-failure.sh migrations/user/20260906-001-remove-legacy-shell-overrides.sh packages/agentos-base/PKGBUILD packages/agentos-runtime/PKGBUILD packages/agentos-runtime/agentos-runtime.install packages/agentos-shell/PKGBUILD packages/agentos-shell/agentos-shell.install agentos/theme/AgentOS.colors agentos/theme/wallpaper.svg agentos/kwin/metadata.json agentos/kwin/contents/code/main.js pacman-hooks/95-btrfs-pre-pacman-snapshot.hook pacman-hooks/96-btrfs-prune-pacman-snapshots.hook systemd/system/agentos-weekly-update.service systemd/system/agentos-weekly-update.timer systemd/system/agentos-boot-health.service systemd/system/workstation-maintenance-check.service systemd/system/workstation-maintenance-check.timer systemd/system/workstation-health-check.service systemd/system/workstation-health-check.timer systemd/system/workstation-rollback-cleanup.service systemd/system/restic-verify.service systemd/system/restic-verify.timer systemd/user/hermes-backup-quick.service systemd/user/hermes-backup-quick.timer systemd/user/hermes-backup-full.service systemd/user/hermes-backup-full.timer site/index.html site/styles.css site/robots.txt site/sitemap.xml site/og-agentos.svg site/og-agentos.png)
required_assets+=(core/internal/hardware/firmware.go core/internal/hardware/firmware_test.go)
required_assets+=(core/internal/recovery/contract.go core/internal/recovery/contract_test.go core/cmd/agentos-ops/recovery.go core/cmd/agentos-ops/recovery_test.go migrations/system/20260907-001-expose-recovery-metadata.sh)
required_assets+=(agentos-onboarding.sh tests/onboarding.sh agentos-vps-install.sh tests/vps-install.sh tests/config.sh)
required_assets+=(docs/help.md docs/troubleshooting.md docs/friend-system-acceptance.md docs/vps-onboarding.md docs/vps-providers.md docs/releasing.md docs/seo-keyword-strategy.md docs/decisions/ADR-001-native-workspace-qml.md docs/decisions/ADR-002-typed-operations-in-go.md agentos/native-shell/Main.qml agentos/desktop/agentos-help.desktop agentos/desktop/agentos-native-workspace.desktop)
required_assets+=(.agents/skills/agentos-operator/SKILL.md .agents/skills/agentos-maintainer/SKILL.md .agents/skills/agentos-system/SKILL.md)
required_assets+=(systemd/user/agentos-migrate-notify.service)
required_assets+=(systemd/user/agentos-update-notify.service systemd/user/agentos-update-notify.timer agentos/plasmoids/com.agentos.status/metadata.json agentos/plasmoids/com.agentos.status/contents/ui/main.qml)
required_assets+=(LICENSE)
for asset in "${required_assets[@]}";do [[ -f "$asset" ]]||{ echo "Missing policy asset: $asset" >&2;exit 1;};done

grep -Fq 'MIT License' LICENSE
grep -Fq 'guarded weekly update' README.md
grep -Fq 'Native Workspace is the default graphical surface' README.md
grep -Fq 'Native Workspace is the default graphical surface' docs/decisions/ADR-001-native-workspace-qml.md
grep -Fq 'Chromium Home remains installed as the recovery fallback' docs/decisions/ADR-001-native-workspace-qml.md
! grep -Fq 'Chromium Home remains the default fallback' docs/decisions/ADR-001-native-workspace-qml.md
! grep -Fq 'There are no unattended Arch upgrades' README.md || { echo 'README contradicts the stable scheduled-update policy.' >&2;exit 1; }
! grep -Fq 'opt-in native' README.md || { echo 'README contradicts the completed native-shell cutover.' >&2;exit 1; }
! grep -Fq 'signed and transactional' docs/help.md || { echo 'Help overstates the updater snapshot guarantee.' >&2;exit 1; }

grep -Fq 'agentos-ops' agentos-cli.sh
grep -Fq 'agentos-ops' agentos-repository.sh
grep -Fq 'agentos-ops' agentos-transaction.sh
grep -Fq 'agentos-ops' agentos-onboarding.sh
grep -Fq 'agentos-ops' agentos-weekly-update.sh
grep -Fq 'agentos-ops' workstation-doctor.sh

grep -Fq 'https://herdr.dev/install.sh' install-agent-tools.sh
grep -Fq 'herdr integration install claude' install-agent-tools.sh
grep -Fq 'herdr integration install codex' install-agent-tools.sh
grep -Fq 'herdr integration install hermes' install-agent-tools.sh
grep -Fq 'hermes --version' install-agent-tools.sh
! grep -Fq 'hermes version' install-agent-tools.sh || { echo 'Unsupported Hermes version subcommand found.' >&2;exit 1; }
grep -Fq 'fpath=("$HOME/.zfunc" $fpath)' dotfiles/.zshrc

grep -Fq 'setup-project-layout' sync-workstation.sh
grep -Fq 'AGENTOS_REPO is not configured' sync-workstation.sh
grep -Fq 'does not match the configured repository' sync-workstation.sh
! grep -EqI 'github\.com[:/][A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' sync-workstation.sh
grep -Fq 'SRC_ROOT="${SRC_ROOT:-$HOME/src}"' setup-project-layout.sh
grep -Fq 'WORKTREE_ROOT="${WORKTREE_ROOT:-$HOME/worktrees}"' setup-project-layout.sh
grep -Fq 'alias csrc=' dotfiles/.zsh/aliases.zsh

grep -Fq 'AGENTOS_CONFIG_FILE=/etc/agentos/config.yaml' apply-system-policy.sh
grep -Fq '[[ ! -e "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]]' ensure-agentos-config.sh
grep -Fq 'channel: $channel' ensure-agentos-config.sh
grep -Fq '/usr/lib/agentos/ensure-agentos-config' packages/agentos-runtime/agentos-runtime.install
grep -Fq '/usr/bin/agentos-power-policy apply' packages/agentos-runtime/agentos-runtime.install
grep -Fq 'agentos-herdr-bridge.service' sync-workstation.sh
grep -Fq 'agentos-boot-health arm' sync-workstation.sh
grep -Fq 'OnCalendar=Sun 06:00' systemd/system/agentos-weekly-update.timer
grep -Fq 'entrypoint update' agentos-weekly-update.sh
grep -Fq 'pacman", "-Syu", "--noconfirm' core/cmd/agentos-ops/main.go
grep -Fq 'entrypoint doctor' workstation-doctor.sh
grep -Fq 'channel != "stable"' core/cmd/agentos-ops/main.go
grep -Fq 'case "store"' core/cmd/agentos-ops/main.go
grep -Fq 'case "config"' core/cmd/agentos-ops/main.go
grep -Fq 'case "support"' core/cmd/agentos-ops/main.go
grep -Fq 'case "telemetry"' core/cmd/agentos-ops/main.go
grep -Fq 'AGENTOS_PACMAN_INCLUDE' core/cmd/agentos-ops/main.go
grep -Fq 'agentos config init|plan|apply' core/cmd/agentos-ops/main.go
grep -Fq 'agentos maintenance' docs/help.md
grep -Fq 'Disposable x86_64 VM journey' docs/friend-system-acceptance.md
grep -Fq 'Firmware apply is not part of the VM journey' docs/friend-system-acceptance.md
grep -Fq 'agentos migrate status --json' docs/help.md
grep -Fq 'agentos hardware --json' docs/help.md
grep -Fq 'agentos.hardware/v1' core/internal/hardware/contract.go
grep -Fq 'agentos.firmware-result/v1' core/internal/hardware/firmware.go
grep -Fq 'firmware-apply --confirm' docs/help.md
grep -Fq -- '--no-unreported-check' core/internal/hardware/firmware.go
grep -Fq "'libnotify'" packages/agentos-runtime/PKGBUILD
grep -Fq 'case "hardware"' core/cmd/agentos-ops/main.go
grep -Fq 'agentos.maintenance/v1' core/internal/maintenance/contract.go
grep -Fq 'migration-apply-user' core/cmd/agentosd2/main.go
grep -Fq 'agentos-migrate-notify.service' packages/agentos-runtime/agentos-runtime.install
grep -Fq 'agentos-update-notify.timer' packages/agentos-runtime/agentos-runtime.install
grep -Fq 'DisallowUnknownFields' core/cmd/agentosd2/main.go
grep -Fq 'migrations/*' tests/package-version.sh
grep -Fq '/usr/share/agentos/migrations' packages/agentos-runtime/PKGBUILD
grep -Fq 'configInitializer' core/cmd/agentos-ops/main.go
grep -Fqx 'module agentos/core' core/go.mod
grep -Fq 'qt6-declarative' packages/agentos-shell/PKGBUILD
grep -Fq 'agentos-native-workspace' packages/agentos-shell/PKGBUILD
! grep -EqI 'github\.com[:/][A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' packages/agentos-base/PKGBUILD
! grep -EqI 'github\.com[:/][A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' packages/agentos-runtime/PKGBUILD
! grep -EqI 'github\.com[:/][A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' packages/agentos-shell/PKGBUILD
grep -Fq 'ApplicationWindow' agentos/native-shell/Main.qml
grep -Fq 'activate task manager entry $view' agentos-shell.sh
grep -Fq 'XMLHttpRequest' agentos/native-shell/Main.qml
grep -Fq '/v1/state' agentos/native-shell/Main.qml
grep -Fq 'property var stateRequest' agentos/native-shell/Main.qml
grep -Fq 'property bool refreshQueued' agentos/native-shell/Main.qml
grep -Fq 'if (loading) { refreshQueued = true; return }' agentos/native-shell/Main.qml
grep -Fq 'interval: 30000' agentos/native-shell/Main.qml
grep -Fq 'stateRequestWatchdog' agentos/native-shell/Main.qml
grep -Fq 'stateRequest.abort()' agentos/native-shell/Main.qml
grep -Fq 'StackLayout' agentos/native-shell/Main.qml
grep -Fq 'Agents' agentos/native-shell/Main.qml
grep -Fq 'Activity' agentos/native-shell/Main.qml
grep -Fq 'System' agentos/native-shell/Main.qml
grep -Fq 'Recovery Center' agentos/native-shell/Main.qml
grep -Fq 'Hardware readiness' agentos/native-shell/Main.qml
grep -Fq 'Support & privacy' agentos/native-shell/Main.qml
grep -Fq 'Start here' agentos/native-shell/Main.qml
grep -Fq 'sendAction("support"' agentos/native-shell/Main.qml
grep -Fq 'activeFocusOnTab: true' agentos/native-shell/Main.qml
grep -Fq 'recovery_point_id' agentos/native-shell/Main.qml
grep -Fq 'sendAction("recovery-stage"' agentos/native-shell/Main.qml
grep -Fq 'sendAction("recovery-cancel"' agentos/native-shell/Main.qml
! grep -Fq 'recovery-delete' agentos/native-shell/Main.qml
grep -Fq 'Command palette' agentos/native-shell/Main.qml
grep -Fq 'agent-start' agentos/native-shell/Main.qml
grep -Fq 'developer_tools' agentos/native-shell/Main.qml
grep -Fq 'Popup' agentos/native-shell/Main.qml
grep -Fq 'pacman -Syu --needed --noconfirm "${PACKAGES[@]}"' sync-workstation.sh
grep -Fq 'bash "$CHECKOUT/install-dotfiles.sh"' sync-workstation.sh
grep -Fq 'AGENTOS_DOTFILES_REPO' install-dotfiles.sh
grep -Fq 'NVIM_LINUX_PATH="$(lua_single_quote "$SOURCE_DIR/nvim-linux.lua")"' install-dotfiles.sh
! grep -EqI 'github\.com[:/][A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' install-dotfiles.sh
grep -Fq 'tpm2-tss mkinitcpio-systemd-tool tinyssh busybox' agentos-encryption.sh
grep -Fq 'repo-add' repository/build-repo.sh
grep -Fq 'AGENTOS_SIGN_KEY' repository/build-repo.sh
grep -Fq '"channel": "stable"' release/channels/stable.json
grep -Fq '"capabilities"' registry/capabilities.json
jq -e '.schema == 1 and (.capabilities | type == "array")' registry/capabilities.json >/dev/null
grep -Fxq 'go' packages.txt
grep -Fxq 'busybox' packages.txt

# Transactional convergence protects remote access and stages recovery.
grep -Fq 'Convergence preflight' sync-workstation.sh
grep -Fq 'rollback-workstation' core/cmd/agentos-ops/main.go
grep -Fq 'rollback-staged' core/cmd/agentos-ops/main.go

# Boot health gate validates the candidate once and prevents rollback loops.
grep -Fq 'boot-candidate.json' agentos-boot-health.sh
grep -Fq 'boot_id' agentos-boot-health.sh
grep -Fq 'attempts >= 1' agentos-boot-health.sh
grep -Fq 'ROLLBACK_PENDING' agentos-boot-health.sh
grep -Fq 'systemctl reboot' agentos-boot-health.sh
grep -Fq 'ConditionPathExists=/var/lib/agentos/boot-candidate.json' systemd/system/agentos-boot-health.service
grep -Fq 'Keeping AgentOS armed recovery snapshot' btrfs-prune-snapshots.sh

# Persistent runtime owns authoritative session state, tools and artifacts.
runtime=core/cmd/agentosd2/main.go
grep -Fq '/v1/state' "$runtime"
grep -Fq '/v1/sessions' "$runtime"
grep -Fq '/v1/events' "$runtime"
grep -Fq '/v1/action' "$runtime"
grep -Fq 'sessions.json' "$runtime"
grep -Fq 'events.jsonl' "$runtime"
grep -Fq 'mergedSessions' "$runtime"
grep -Fq 'process-exit' "$runtime"
grep -Fq 'StateThinking' "$runtime"
grep -Fq 'StateWaiting' "$runtime"
grep -Fq 'StateBlocked' "$runtime"
grep -Fq 'AttentionItem' "$runtime"
grep -Fq 'agent-stop' "$runtime"
grep -Fq 'agent-attach' "$runtime"
grep -Fq 'agent-logs' "$runtime"
grep -Fq 'project-diff' "$runtime"
grep -Fq 'open-pr' "$runtime"
grep -Fq 'Tool ToolCall' "$runtime"
grep -Fq 'Artifacts []Artifact' "$runtime"
grep -Fq 'BtrfsErrors' "$runtime"
grep -Fq 'DeveloperTools' "$runtime"
grep -Fq 'environmentForVirtualization' "$runtime"
grep -Fq 'SystemSetting' "$runtime"
grep -Fq 'systemSettingDefinitions' "$runtime"
grep -Fq 'kcm_networkmanagement' "$runtime"
grep -Fq 'Models' "$runtime"
grep -Fq 'Updates' "$runtime"
grep -Fq 'agentosCommand' core/cmd/agentos-ops/main.go
grep -Fq 'pacmanInc' core/cmd/agentos-ops/main.go
grep -Fq 'updateCommand' core/cmd/agentos-ops/main.go
test -x ensure-repository-config.sh
grep -Fq 'systemctl --user restart agentosd.service' sync-workstation.sh
grep -Fq './cmd/agentosd2' packages/agentos-runtime/PKGBUILD
grep -Fq 'makedepends=('"'"'go'"'"')' packages/agentos-runtime/PKGBUILD
grep -Fq 'install -Dm755 "$src/repository/verify-repo.sh" "$pkgdir/usr/lib/agentos/verify-repo.sh"' packages/agentos-runtime/PKGBUILD
grep -Fq 'curl -fsS --max-time 3 -X POST' agentos-agent-event.sh
grep -Fq 'AGENTOS_NATIVE_EVENT_DRY_RUN' agentos-native-event.sh
grep -Fq '/usr/bin/agentos-native-event' install-agent-tools.sh
grep -Fq '/usr/local/bin/agentos-native-event' packages/agentos-runtime/agentos-runtime.install
grep -Fq 'observer-only' agentos-native-event.sh
grep -Fq 'sha256:' agentos-native-event.sh
grep -Fq 'file_operation_input' agentos-native-event.sh
grep -Fq 'file_before' agentos-native-event.sh
grep -Fq 'text_value' agentos-hermes-plugin/__init__.py
grep -Fq 'native_event_command' agentos-hermes-plugin/__init__.py
grep -Fq 'hermes plugins enable agentos-observability' install-agent-tools.sh
grep -Fq 'https://opencode.ai/install' install-agent-tools.sh
grep -Fq 'sync-workstation --opencode --ide vscode' README.md
grep -Fq 'sudo ./install.sh --opencode --ide vscode' README.md
grep -Fq 'USERNAME="${USERNAME:-}"' install.sh
grep -Fq 'AGENTOS_REPO HTTP(S) URLs must not contain userinfo' apply-system-policy.sh
grep -Fq 'tooling.env' bootstrap.sh
grep -Fq 'case "$IDE" in' update-workstation.sh
grep -Fq 'Hermes backup recipients are not configured; skipping backup.' hermes-backup.sh
grep -Fq '    return 1' hermes-backup.sh

# Herdr bridge converts semantic lifecycle state into AgentOS events.
grep -Fq 'herdr agent list' agentos-herdr-bridge.sh
grep -Fq 'agent_status' agentos-herdr-bridge.sh
grep -Fq 'working) echo RUNNING' agentos-herdr-bridge.sh
grep -Fq 'blocked) echo BLOCKED' agentos-herdr-bridge.sh
grep -Fq 'idle) echo WAITING' agentos-herdr-bridge.sh
grep -Fq 'ExecStart=/usr/bin/agentos-herdr-bridge' systemd/user/agentos-herdr-bridge.service
grep -Fq "ExecCondition=/usr/bin/bash -c 'command -v herdr >/dev/null 2>&1'" systemd/user/agentos-herdr-bridge.service
grep -Fq 'Environment=PATH=%h/.local/bin:/usr/bin' systemd/user/agentosd.service

# Home is the sole shell surface and exposes real active work.
grep -Fq '/v1/healthz' agentos-home.sh
grep -Fq "self.proxy('/v1/state')" agentos-home.sh
grep -Fq "self.proxy('/v1/action'" agentos-home.sh
grep -Fq 'attention-acknowledge' agentos-home.sh
grep -Fq 'attention-dismiss' agentos-home.sh
grep -Fq 'aria-label="Acknowledge' agentos-home.sh
grep -Fq '/api/ui-command' agentos-home.sh
grep -Fq 'Active work' agentos-home.sh
grep -Fq 'sessionCard' agentos-home.sh
grep -Fq 'Attention inbox' agentos-home.sh
grep -Fq 'project-diff' agentos-home.sh
grep -Fq 'agent-stop' agentos-home.sh
grep -Fq 'Resource attribution' agentos-home.sh
grep -Fq 'Runtime events' agentos-home.sh
grep -Fq 'Loaded models' agentos-home.sh
grep -Fq 'Developer tools' agentos-home.sh
grep -Fq 'System settings' agentos-home.sh
grep -Fq 'settingsSummary' agentos-home.sh
grep -Fq 'Bluetooth settings' agentos-home.sh
grep -Fq 'Mouse settings' agentos-home.sh
grep -Fq 'Check updates' agentos-home.sh
grep -Fq 'Update now' agentos-home.sh
grep -Fq 'Recovery Center' agentos-home.sh
grep -Fq 'Hardware readiness' agentos-home.sh
grep -Fq 'Support &amp; privacy' agentos-home.sh
grep -Fq 'Start here' agentos-home.sh
grep -Fq "action('support')" agentos-home.sh
grep -Fq ':focus-visible' agentos-home.sh
grep -Fq 'recovery_point_id' agentos-home.sh
grep -Fq "action('recovery-stage'" agentos-home.sh
grep -Fq "action('recovery-cancel'" agentos-home.sh
! grep -Fq 'recovery-delete' agentos-home.sh
grep -Fq 'System information is loading' agentos-home.sh
grep -Fq 'System information unavailable' agentos-home.sh
grep -Fq 'Command palette' agentos-home.sh
grep -Fq -- '--kiosk' agentos-home.sh
grep -Fq -- '--start-maximized' agentos-home.sh
grep -Fq 'ui-command' agentos-ui.sh
grep -Fq 'registerShortcut' agentos/kwin/contents/code/main.js
grep -Fq "'Meta+K'" agentos/kwin/contents/code/main.js
grep -Fq "'F8'" agentos/kwin/contents/code/main.js
grep -Fq "'Meta+1'" agentos/kwin/contents/code/main.js
grep -Fq "'Ctrl+Alt+H'" agentos/kwin/contents/code/main.js
for view in 1 2 3 4; do grep -Fq "'Ctrl+Alt+$view'" agentos/kwin/contents/code/main.js; done
grep -Fq 'workspace.raiseWindow' agentos/kwin/contents/code/main.js
grep -Fq 'workspace.windowAdded.connect' agentos/kwin/contents/code/main.js
grep -Fq 'workspace.sendClientToScreen' agentos/kwin/contents/code/main.js
grep -Fq 'indexOf('\''krdp'\'')' agentos/kwin/contents/code/main.js
grep -Fq 'StopUnit' agentos/kwin/contents/code/main.js
grep -Fq 'agentos-ui@.service' agentos-desktop.sh
grep -Fq 'systemctl --user start agentos-native-workspace.service' agentos-desktop.sh
grep -Fq 'systemctl enable plasmalogin' bootstrap.sh
grep -Fq 'systemctl set-default graphical.target' bootstrap.sh
grep -Fq 'plasma-login-manager' packages.txt
grep -Fq '== --sync || "$MODE" == --enable' agentos-desktop.sh
grep -Fq 'Chromium Home stays' agentos-desktop.sh
grep -Fq 'activityPageSize: 8' agentos/native-shell/Main.qml
grep -Fq 'id: activitySearch' agentos/native-shell/Main.qml
grep -Fq 'Qt.application.arguments' agentos/native-shell/Main.qml
grep -Fq 'Update now' agentos/native-shell/Main.qml
grep -Fq 'Last successful update' agentos/native-shell/Main.qml
grep -Fq 'update-center-open' agentos/plasmoids/com.agentos.status/contents/ui/main.qml
grep -Fq 'Accessible.name' agentos/plasmoids/com.agentos.status/contents/ui/main.qml
grep -Fq 'http://127.0.0.1:4787/v1/state' agentos/plasmoids/com.agentos.status/contents/ui/main.qml
grep -Fq 'root.activityPageEvents' agentos/native-shell/Main.qml
grep -Fq 'No events match this search.' agentos/native-shell/Main.qml
grep -Fq -- '--responsive' clients/macos/agentos-rdp
grep -Fq '"/bpp:16"' clients/macos/agentos-rdp
grep -Fq '"/gfx:progressive:off"' clients/macos/agentos-rdp
! grep -Fq "'agentos-control.sh agentos-control'" apply-system-policy.sh
! grep -Fq "'agentos-launcher.sh agentos-launcher'" apply-system-policy.sh

# Desktop/RDP contract.
grep -Fq '/usr/share/archiso/configs/releng' build-agentos-iso.sh
grep -Fq 'agentos-desktop --sync' sync-workstation.sh
grep -Fq 'plasma-meta plasma-login-manager dolphin' agentos-desktop.sh
grep -Fq 'ColorScheme AgentOS' agentos-desktop.sh
grep -Fq 'agentos-shellEnabled true' agentos-desktop.sh
grep -Fq 'fullscreen=true' agentos-shell.sh
grep -Fxq 'krdp' packages.txt
grep -Fq 'SystemUserEnabled true' agentos-remote-desktop.sh
grep -Fq 'Certificate "$KRDP_CERT"' agentos-remote-desktop.sh
grep -Fq 'app-org.kde.krdpserver.service' agentos-remote-desktop.sh

# Always-on power policy.

mapfile -t packages < <(grep -Ev '^[[:space:]]*(#|$)' packages.txt)
[[ ${#packages[@]} -gt 0 ]]||{ echo 'packages.txt is empty.' >&2;exit 1;}
duplicates="$(printf '%s\n' "${packages[@]}"|sort|uniq -d)";[[ -z "$duplicates" ]]||{ printf 'Duplicate package entries:\n%s\n' "$duplicates" >&2;exit 1;}
if command -v pacman >/dev/null 2>&1;then missing=0;for package in "${packages[@]}";do if ! pacman -Si "$package" >/dev/null 2>&1;then echo "Package not found in synced Arch repositories: $package" >&2;missing=1;fi;done;(( missing == 0 ))||exit 1;fi
if command -v go >/dev/null 2>&1;then (cd core && go test ./...);fi
bash tests/agentos-skills.sh
echo 'Static validation passed.'
