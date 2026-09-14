function homeWindow() {
    const windows = workspace.windowList();
    for (let i = 0; i < windows.length; i++) {
        const w = windows[i];
        const cls = String(w.resourceClass || '').toLowerCase();
        const cap = String(w.caption || '').toLowerCase();
        if (cls.indexOf('agentos-home') !== -1 || cap === 'agentos' || cap.indexOf('agentos') === 0) {
            return w;
        }
    }
    return null;
}

function nativeWindow() {
    const windows = workspace.windowList();
    for (let i = 0; i < windows.length; i++) {
        const w = windows[i];
        const cls = String(w.resourceClass || '').toLowerCase();
        const cap = String(w.caption || '').toLowerCase();
        if (cls.indexOf('agentos-native-workspace') !== -1 || cap === 'agentos workspace') {
            return w;
        }
    }
    return null;
}

function remoteOutput() {
    const screens = workspace.screens;
    for (let i = 0; i < screens.length; i++) {
        if (String(screens[i].name || '').toLowerCase().indexOf('krdp') !== -1) return screens[i];
    }
    return null;
}

function activateWindow(w, output) {
    if (!w) return;
    if (output) workspace.sendClientToScreen(w, output);
    w.minimized = false;
    workspace.raiseWindow(w);
    workspace.activeWindow = w;
}

function startUnit(unit) {
    callDBus(
        'org.freedesktop.systemd1',
        '/org/freedesktop/systemd1',
        'org.freedesktop.systemd1.Manager',
        'StartUnit',
        unit,
        'replace'
    );
}

function stopUnit(unit) {
    callDBus(
        'org.freedesktop.systemd1',
        '/org/freedesktop/systemd1',
        'org.freedesktop.systemd1.Manager',
        'StopUnit',
        unit,
        'replace'
    );
}

function dispatchHome(command) {
    activateWindow(homeWindow());
    startUnit('agentos-ui@' + command + '.service');
    stopUnit('agentos-native-workspace.service');
}

function dispatchNativeWorkspace() {
    const target = remoteOutput() || workspace.activeScreen;
    const w = nativeWindow();
    if (w) {
        activateWindow(w, target);
        return;
    }
    pendingNativeOutput = target;
    startUnit('agentos-native-workspace.service');
}

let pendingNativeOutput = null;
workspace.windowAdded.connect(function(w) {
    const cls = String(w.resourceClass || '').toLowerCase();
    const cap = String(w.caption || '').toLowerCase();
    if (cls.indexOf('agentos-native-workspace') === -1 && cap !== 'agentos workspace') return;
    const target = pendingNativeOutput || workspace.activeScreen;
    pendingNativeOutput = null;
    activateWindow(w, target);
});

registerShortcut('AgentOSPalette', 'AgentOS Command Palette', 'Meta+K', function() { dispatchHome('palette'); });
registerShortcut('AgentOSPaletteFallback', 'AgentOS Command Palette fallback', 'F8', function() { dispatchHome('palette'); });
registerShortcut('AgentOSHome', 'AgentOS Home', 'Meta+H', function() { dispatchHome('workspace'); });
registerShortcut('AgentOSWorkspace', 'AgentOS Workspace', 'Meta+1', function() { dispatchNativeWorkspace(); });
registerShortcut('AgentOSAgents', 'AgentOS Agents', 'Meta+2', function() { dispatchHome('agents'); });
registerShortcut('AgentOSActivity', 'AgentOS Activity', 'Meta+3', function() { dispatchHome('activity'); });
registerShortcut('AgentOSSystem', 'AgentOS System', 'Meta+4', function() { dispatchHome('system'); });

// macOS reserves several Command shortcuts before SDL FreeRDP can forward the
// complete key sequence. Keep the Meta bindings for local Plasma and provide
// Ctrl+Alt aliases that traverse the Mac -> FreeRDP -> KWin input path intact.
registerShortcut('AgentOSHomeRDP', 'AgentOS Home (RDP)', 'Ctrl+Alt+H', function() { dispatchHome('workspace'); });
registerShortcut('AgentOSWorkspaceRDP', 'AgentOS Workspace (RDP)', 'Ctrl+Alt+1', function() { dispatchNativeWorkspace(); });
registerShortcut('AgentOSAgentsRDP', 'AgentOS Agents (RDP)', 'Ctrl+Alt+2', function() { dispatchHome('agents'); });
registerShortcut('AgentOSActivityRDP', 'AgentOS Activity (RDP)', 'Ctrl+Alt+3', function() { dispatchHome('activity'); });
registerShortcut('AgentOSSystemRDP', 'AgentOS System (RDP)', 'Ctrl+Alt+4', function() { dispatchHome('system'); });
