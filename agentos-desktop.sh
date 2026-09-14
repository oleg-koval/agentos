#!/usr/bin/env bash
# Install/sync the AgentOS desktop experience on top of KDE Plasma.
set -euo pipefail

MODE="${1:---sync}"
SOURCE_DIR="${AGENTOS_SOURCE_DIR:-$HOME/.local/share/agentos/repo}"
if [[ ! -e "$SOURCE_DIR" && -d "$HOME/.local/share/legacy-workstation/repo" ]]; then SOURCE_DIR="$HOME/.local/share/legacy-workstation/repo"; fi

if [[ ${EUID} -eq 0 ]]; then echo 'Run agentos-desktop as the workstation user, not root.' >&2; exit 1; fi
case "$MODE" in --sync|--enable|--status) ;; *) echo 'Usage: agentos-desktop [--sync|--enable|--status]' >&2; exit 2 ;; esac

if [[ "$MODE" == --status ]]; then
  printf 'Plasma: '; command -v plasmashell >/dev/null 2>&1 && echo installed || echo missing
  printf 'AgentOS color scheme: '; [[ -f "$HOME/.local/share/color-schemes/AgentOS.colors" ]] && echo installed || echo missing
  printf 'AgentOS wallpaper: '; [[ -f "$HOME/.local/share/wallpapers/AgentOS/contents/images/3840x2160.svg" ]] && echo installed || echo missing
  printf 'AgentOS Home: '; command -v agentos-home >/dev/null 2>&1 && echo installed || echo missing
  printf 'AgentOS UI bridge: '; command -v agentos-ui >/dev/null 2>&1 && echo installed || echo missing
  printf 'AgentOS Native Workspace: '; command -v agentos-native-workspace >/dev/null 2>&1 && echo installed || echo missing
  printf 'AgentOS KWin shortcuts: '; [[ -f "$HOME/.local/share/kwin/scripts/agentos-shell/contents/code/main.js" ]] && echo installed || echo missing
  printf 'AgentOS shell command: '; command -v agentos-shell >/dev/null 2>&1 && echo installed || echo missing
  printf 'Graphical target: '; systemctl get-default
  printf 'Home autostart: '; systemctl --user is-enabled agentos-home.service 2>/dev/null || echo disabled
  printf 'Home runtime: '; systemctl --user is-active agentos-home.service 2>/dev/null || echo inactive
  printf 'Native runtime: '; systemctl --user is-active agentos-native-workspace.service 2>/dev/null || echo inactive
  printf 'Login manager: '; if systemctl is-enabled plasmalogin.service >/dev/null 2>&1; then echo 'plasmalogin enabled'; elif [[ -L /etc/systemd/system/display-manager.service ]]; then readlink -f /etc/systemd/system/display-manager.service; else echo 'not enabled'; fi
  exit 0
fi

[[ -f "$SOURCE_DIR/agentos/theme/AgentOS.colors" ]] || { echo 'AgentOS theme assets missing. Run sync-workstation.' >&2; exit 1; }
[[ -f "$SOURCE_DIR/agentos/kwin/metadata.json" && -f "$SOURCE_DIR/agentos/kwin/contents/code/main.js" ]] || { echo 'AgentOS KWin shortcut assets missing.' >&2; exit 1; }
sudo pacman -S --needed --noconfirm plasma-meta plasma-login-manager dolphin python
package_shell=false
pacman -Q agentos-shell >/dev/null 2>&1 && package_shell=true

install -d -m 755 "$HOME/.local/share/color-schemes" "$HOME/.local/share/wallpapers/AgentOS/contents/images" "$HOME/.local/share/applications" "$HOME/.local/share/plasma/plasmoids" "$HOME/.local/share/kwin/scripts" "$HOME/.config/autostart-scripts" "$HOME/.config/systemd/user" "$HOME/Desktop"
install -m 644 "$SOURCE_DIR/agentos/theme/AgentOS.colors" "$HOME/.local/share/color-schemes/AgentOS.colors"
install -m 644 "$SOURCE_DIR/agentos/theme/wallpaper.svg" "$HOME/.local/share/wallpapers/AgentOS/contents/images/3840x2160.svg"
if [[ -d "$SOURCE_DIR/agentos/plasmoids/com.agentos.status" ]]; then rm -rf "$HOME/.local/share/plasma/plasmoids/com.agentos.status"; cp -a "$SOURCE_DIR/agentos/plasmoids/com.agentos.status" "$HOME/.local/share/plasma/plasmoids/"; fi
cp -a "$SOURCE_DIR/agentos/desktop/." "$HOME/.local/share/applications/"
rm -f "$HOME/.local/share/applications/agentos-launcher.desktop" "$HOME/.local/share/applications/agentos-control.desktop"
rm -rf "$HOME/.local/share/kwin/scripts/agentos-shell"
cp -a "$SOURCE_DIR/agentos/kwin" "$HOME/.local/share/kwin/scripts/agentos-shell"

cat > "$HOME/.local/share/applications/agentos-home.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=AgentOS Home
Comment=Primary persistent agent workspace
Exec=agentos-home
Icon=computer
Terminal=false
Categories=System;Development;
StartupWMClass=AgentOS-Home
EOF

make_ui_entry() {
  local file="$1" name="$2" cmd="$3"
  cat > "$HOME/.local/share/applications/$file" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Exec=agentos-ui $cmd
Icon=computer
Terminal=false
NoDisplay=true
EOF
}
make_ui_entry agentos-palette.desktop 'AgentOS Command Palette' palette
make_ui_entry agentos-palette-f8.desktop 'AgentOS Command Palette fallback' palette
make_ui_entry agentos-view-workspace.desktop 'AgentOS Workspace' workspace
make_ui_entry agentos-view-agents.desktop 'AgentOS Agents' agents
make_ui_entry agentos-view-activity.desktop 'AgentOS Activity' activity
make_ui_entry agentos-view-system.desktop 'AgentOS System' system

if [[ "$package_shell" == true ]]; then
  rm -f "$HOME/.config/systemd/user/agentos-ui@.service"
else
  cat > "$HOME/.config/systemd/user/agentos-ui@.service" <<'EOF'
[Unit]
Description=Dispatch AgentOS Home UI command %i
After=graphical-session.target agentos-home.service

[Service]
Type=oneshot
ExecStart=/usr/bin/agentos-ui %i
EOF
fi

for shortcut in 'AgentOS Control' Launcher Terminal Files Browser Claude Codex Hermes Herdr; do rm -f "$HOME/Desktop/$shortcut.desktop"; done

if command -v kwriteconfig6 >/dev/null 2>&1; then
  kwriteconfig6 --file kdeglobals --group General --key ColorScheme AgentOS
  kwriteconfig6 --file kdeglobals --group KDE --key SingleClick false
  kwriteconfig6 --file kwinrc --group Windows --key FocusPolicy ClickToFocus
  kwriteconfig6 --file plasmarc --group Theme --key name breeze-dark
  kwriteconfig6 --file kwinrc --group Plugins --key agentos-shellEnabled true
fi

if [[ "$package_shell" != true ]]; then
  sudo install -d -m 755 /usr/share/wallpapers/AgentOS
  sudo install -m 644 "$SOURCE_DIR/agentos/theme/wallpaper.svg" /usr/share/wallpapers/AgentOS/wallpaper.svg
fi

if [[ "$package_shell" == true ]]; then
  rm -f "$HOME/.config/systemd/user/agentos-home.service"
else
  cat > "$HOME/.config/systemd/user/agentos-home.service" <<'EOF'
[Unit]
Description=AgentOS Home shell
After=graphical-session.target agentosd.service
Wants=agentosd.service
PartOf=graphical-session.target

[Service]
Type=simple
ExecStartPre=/usr/bin/sh -c 'for i in $(seq 1 60); do [ -n "$WAYLAND_DISPLAY" ] && exit 0; sleep 1; done; exit 1'
ExecStart=/usr/bin/agentos-home
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF
fi

cat > "$HOME/.config/autostart-scripts/agentos-session.sh" <<'EOF'
#!/usr/bin/env bash
sleep 3
systemctl --user import-environment WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS >/dev/null 2>&1 || true
dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS >/dev/null 2>&1 || true
systemctl --user restart agentosd.service >/dev/null 2>&1 || true
agentos-shell >/dev/null 2>&1 || true
systemctl --user restart agentos-home.service >/dev/null 2>&1 || true
# Native Workspace is the default graphical surface; Chromium Home stays
# running underneath as the recovery fallback.
systemctl --user start agentos-native-workspace.service >/dev/null 2>&1 || true
EOF
chmod 755 "$HOME/.config/autostart-scripts/agentos-session.sh"

systemctl --user daemon-reload || true
systemctl --user enable agentos-home.service >/dev/null 2>&1 || true

if [[ "$MODE" == --sync || "$MODE" == --enable ]]; then
  sudo systemctl set-default graphical.target
  if systemctl list-unit-files plasmalogin.service >/dev/null 2>&1; then sudo systemctl enable plasmalogin.service; else echo 'Plasma Login Manager service not found.' >&2; exit 1; fi
fi

if [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* || "${XDG_CURRENT_DESKTOP:-}" == *Plasma* ]]; then
  systemctl --user import-environment WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS >/dev/null 2>&1 || true
  dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS >/dev/null 2>&1 || true
  kbuildsycoca6 >/dev/null 2>&1 || true
  agentos-shell || true
  systemctl --user restart agentosd.service >/dev/null 2>&1 || true
  systemctl --user restart agentos-home.service >/dev/null 2>&1 || true
fi

echo 'AgentOS desktop synchronized. Home is the single shell surface; KWin owns global activation and view shortcuts.'
