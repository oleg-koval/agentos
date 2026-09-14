#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -eq 0 ]]; then echo 'Run agentos-shell as the workstation user.' >&2; exit 1; fi
if [[ "${XDG_CURRENT_DESKTOP:-}" != *KDE* && "${XDG_CURRENT_DESKTOP:-}" != *Plasma* ]]; then echo 'Run agentos-shell from the active Plasma session.' >&2; exit 1; fi
command -v qdbus6 >/dev/null 2>&1 || { echo 'qdbus6 not found.' >&2; exit 1; }

qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript '
var ps = panels();
for (var i = ps.length - 1; i >= 0; --i) { ps[i].remove(); }
' >/dev/null

kwriteconfig6 --file kwinrc --group Windows --key BorderlessMaximizedWindows true
kwriteconfig6 --file kwinrc --group Windows --key FocusPolicy ClickToFocus
kwriteconfig6 --file kwinrc --group Desktops --key Number 4
kwriteconfig6 --file kwinrc --group Desktops --key Rows 1
kwriteconfig6 --file kdeglobals --group General --key ColorScheme AgentOS
kwriteconfig6 --file kdeglobals --group KDE --key SingleClick false
kwriteconfig6 --file kwinrc --group Plugins --key agentos-shellEnabled true

# Remote clients frequently hit exact virtual-screen edges. Disable every edge
# action so pointer translation cannot invoke Overview/Grid/Present Windows.
kwriteconfig6 --file kwinrc --group Windows --key ElectricBorders 0
for edge in Top TopRight Right BottomRight Bottom BottomLeft Left TopLeft; do kwriteconfig6 --file kwinrc --group ElectricBorders --key "$edge" None; done
kwriteconfig6 --file kwinrc --group Effect-overview --key BorderActivate 9
kwriteconfig6 --file kwinrc --group Effect-windowview --key BorderActivate 9
kwriteconfig6 --file kwinrc --group Effect-windowview --key BorderActivateAll 9
kwriteconfig6 --file kwinrc --group Effect-PresentWindows --key BorderActivate 9
kwriteconfig6 --file kwinrc --group Effect-PresentWindows --key BorderActivateAll 9
kwriteconfig6 --file kwinrc --group Effect-DesktopGrid --key BorderActivate 9
kwriteconfig6 --file kwinrc --group TabBox --key BorderActivate 9
kwriteconfig6 --file kwinrc --group TabBox --key BorderAlternativeActivate 9

wall="$HOME/.local/share/wallpapers/AgentOS/contents/images/3840x2160.svg"
kwriteconfig6 --file kscreenlockerrc --group Greeter --key WallpaperPlugin org.kde.image
kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper --group org.kde.image --group General --key Image "file://$wall"

# KWin's AgentOS script owns Meta+K/F8, Meta+H and Meta+1..4, with Ctrl+Alt+H
# and Ctrl+Alt+1..4 aliases for remote desktop clients. Meta+1 launches native
# Workspace; Meta+H raises Chromium Home as the recovery fallback.
# Keep terminal launch as a normal global shortcut because it intentionally
# opens a separate application window.
kwriteconfig6 --file kglobalshortcutsrc --group kitty.desktop --key _launch 'Meta+Return,Meta+Return,Kitty'
kwriteconfig6 --file kglobalshortcutsrc --group agentos-launcher.desktop --key _launch 'none,none,AgentOS Launcher (retired)'
kwriteconfig6 --file kglobalshortcutsrc --group agentos-control.desktop --key _launch 'none,none,AgentOS Control (retired)'
kwriteconfig6 --file kglobalshortcutsrc --group agentos-palette.desktop --key _launch 'none,none,AgentOS palette handled by KWin script'
kwriteconfig6 --file kglobalshortcutsrc --group agentos-palette-f8.desktop --key _launch 'none,none,AgentOS palette fallback handled by KWin script'
kwriteconfig6 --file kglobalshortcutsrc --group agentos-view-workspace.desktop --key _launch 'none,none,AgentOS workspace handled by KWin script'
kwriteconfig6 --file kglobalshortcutsrc --group agentos-view-agents.desktop --key _launch 'none,none,AgentOS agents handled by KWin script'
kwriteconfig6 --file kglobalshortcutsrc --group agentos-view-activity.desktop --key _launch 'none,none,AgentOS activity handled by KWin script'
kwriteconfig6 --file kglobalshortcutsrc --group agentos-view-system.desktop --key _launch 'none,none,AgentOS system handled by KWin script'
# Plasma's default task-manager bindings otherwise collide with AgentOS
# Workspace/Agents/Activity/System shortcuts on Meta+1..4.
for view in 1 2 3 4; do
  kwriteconfig6 --file kglobalshortcutsrc --group plasmashell --key "activate task manager entry $view" "none,none,Activate Task Manager Entry $view"
done

cat > "$HOME/.config/kwinrulesrc" <<'EOF'
[1]
Description=AgentOS Home
wmclass=AgentOS-Home
wmclassmatch=2
title=AgentOS
titlematch=2
noborder=true
noborderrule=2
fullscreen=true
fullscreenrule=2
maximizehoriz=true
maximizehorizrule=2
maximizevert=true
maximizevertrule=2
desktop=1
desktoprule=2
skiptaskbar=true
skiptaskbarrule=2

[General]
count=1
EOF
qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
printf 'AgentOS shell applied: KWin-native Home shortcuts enabled; Meta+Enter terminal; hot corners disabled.\n'
