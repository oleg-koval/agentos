import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: root
    visible: true
    width: 1180
    height: 760
    minimumWidth: 900
    minimumHeight: 560
    title: "AgentOS Workspace"
    color: "#070a10"

    property var snapshot: ({})
    property var stateRequest: null
    property bool refreshQueued: false
    property string errorText: ""
    property bool loading: false
    property int currentView: viewFromArguments()
    property var commands: []
    property var filteredCommands: []
    property string activityQuery: ""
    property int activityPage: 0
    property int activityPageSize: 8
    property int activityPageCount: 1
    property var filteredEvents: []
    property var activityPageEvents: []

    function field(object, name, fallback) {
        return object && object[name] !== undefined ? object[name] : fallback
    }

    function viewFromArguments() {
        var args = Qt.application.arguments || []
        for (var i = 0; i + 1 < args.length; i++) {
            if (args[i] !== "--view") continue
            var views = { workspace: 0, agents: 1, activity: 2, system: 3 }
            if (views[args[i + 1]] !== undefined) return views[args[i + 1]]
        }
        return 0
    }

    function statusColor(status) {
        var normalized = String(status || "").toUpperCase()
        if (["FAILED", "BLOCKED", "CHECK-FAILED", "APPLY-FAILED"].indexOf(normalized) !== -1) return "#ff6474"
        if (["WARNING", "WAITING", "THINKING", "TOOL", "CHECKING", "AVAILABLE", "REBOOT-REQUIRED"].indexOf(normalized) !== -1) return "#ffb84d"
        if (["READY", "RUNNING", "DONE", "HEALTHY", "SUCCEEDED", "UP-TO-DATE"].indexOf(normalized) !== -1) return "#3ddc84"
        return "#7f8a9c"
    }

    function request(method, path, body, done) {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (!done) return
            var callback = done
            done = null
            if (xhr.status >= 200 && xhr.status < 300) callback(true, xhr.responseText)
            else callback(false, xhr.responseText || ("HTTP " + xhr.status))
        }
        xhr.open(method, "http://127.0.0.1:4787" + path, true)
        if (body) xhr.setRequestHeader("Content-Type", "application/json")
        xhr.send(body || "")
        return xhr
    }

    function refresh() {
        if (loading) { refreshQueued = true; return }
        loading = true
        stateRequestWatchdog.restart()
        var xhr = request("GET", "/v1/state", "", function(ok, response) {
            if (stateRequest !== xhr) return
            stateRequest = null
            stateRequestWatchdog.stop()
            loading = false
            if (!ok) errorText = "AgentOS API unavailable. " + response
            else {
                try { snapshot = JSON.parse(response); errorText = "" }
                catch (error) { errorText = "AgentOS returned invalid state: " + error }
            }
            if (refreshQueued) { refreshQueued = false; refresh() }
        })
        stateRequest = xhr
    }

    function cancelStateRequest() {
        if (!stateRequest) return
        stateRequest.onreadystatechange = null
        stateRequest.abort()
        stateRequest = null
        refreshQueued = false
        loading = false
        errorText = "AgentOS API request timed out; retrying soon."
    }

    function sendAction(name, values) {
        var action = { name: name }
        if (values) {
            if (values.agent !== undefined) action.agent = values.agent
            if (values.project !== undefined) action.project = values.project
            if (values.session !== undefined) action.session = values.session
            if (values.pid !== undefined) action.pid = values.pid
            if (values.attention_id !== undefined) action.attention_id = values.attention_id
            if (values.recovery_point_id !== undefined) action.recovery_point_id = values.recovery_point_id
        }
        request("POST", "/v1/action", JSON.stringify(action), function(ok, response) {
            if (!ok) errorText = "Action failed: " + response
            else refresh()
        })
    }

    function openSetting(setting) { sendAction(setting.id, {}) }
    function selectView(index) { currentView = index; palette.close() }
    function firstProject() {
        var projects = field(snapshot, "projects", [])
        return projects.length ? field(projects[0], "name", "") : ""
    }

    function maintenanceActionAvailable(id) {
        var actions = field(field(snapshot, "maintenance", {}), "actions", [])
        for (var i = 0; i < actions.length; i++)
            if (field(actions[i], "id", "") === id) return field(actions[i], "available", false)
        return false
    }

    function recommendedRecoveryPoint() {
        var points = field(field(snapshot, "recovery", {}), "points", [])
        for (var i = 0; i < points.length; i++)
            if (field(points[i], "boot_safe", false)) return points[i]
        return null
    }

    function hardwareLabel(id) {
        var labels = {
            "architecture": "Architecture", "machine-role": "Machine role",
            "boot-mode": "Boot mode", "root-filesystem": "Root filesystem",
            "recovery": "Recovery", "connectivity": "Connectivity",
            "graphical-session": "Graphical session", "firmware-support": "Firmware support"
        }
        return labels[id] || id || "Hardware check"
    }

    function buildCommands() {
        var next = [
            { label: "Workspace", view: 0 }, { label: "Agents", view: 1 },
            { label: "Activity", view: 2 }, { label: "System", view: 3 },
            { label: "New terminal", action: "terminal" }, { label: "Files", action: "files" },
            { label: "Browser", action: "browser" }, { label: "Doctor", action: "doctor" },
            { label: "Create local support report", action: "support" },
            { label: "Check updates", action: "update-check" },
            { label: "Update now", action: "update-apply" }
        ]
        var projects = field(snapshot, "projects", [])
        for (var i = 0; i < projects.length; i++) {
            next.push({ label: "Open project · " + projects[i].name, action: "project-open", project: projects[i].name })
            next.push({ label: "Diff project · " + projects[i].name, action: "project-diff", project: projects[i].name })
        }
        var agents = field(snapshot, "agents", [])
        for (var j = 0; j < agents.length; j++)
            next.push({ label: "Start " + agents[j].name, action: "agent-start", agent: agents[j].id, project: root.firstProject() })
        var settings = field(field(snapshot, "system", {}), "settings", [])
        for (var k = 0; k < settings.length; k++)
            if (settings[k].available) next.push({ label: settings[k].name, setting: settings[k] })
        var recommended = recommendedRecoveryPoint()
        if (recommended && maintenanceActionAvailable("recovery-stage"))
            next.push({ label: "Stage recommended recovery point", action: "recovery-stage", recovery_point_id: recommended.id })
        if (maintenanceActionAvailable("recovery-cancel"))
            next.push({ label: "Cancel staged rollback", action: "recovery-cancel" })
        commands = next
        filteredCommands = next
    }

    function filterCommands(query) {
        var normalized = String(query || "").toLowerCase()
        var matches = []
        for (var i = 0; i < commands.length; i++)
            if (commands[i].label.toLowerCase().indexOf(normalized) !== -1) matches.push(commands[i])
        filteredCommands = matches
    }

    function eventSearchText(event) {
        return [
            field(event, "kind", ""), field(event, "agent", ""),
            field(event, "project", ""), field(event, "text", "")
        ].join(" ").toLowerCase()
    }

    function updateActivityPage() {
        activityPageCount = Math.max(1, Math.ceil(filteredEvents.length / activityPageSize))
        if (activityPage >= activityPageCount) activityPage = activityPageCount - 1
        activityPageEvents = filteredEvents.slice(activityPage * activityPageSize, (activityPage + 1) * activityPageSize)
    }

    function rebuildActivityEvents(resetPage) {
        var events = field(snapshot, "events", [])
        var normalized = String(activityQuery || "").trim().toLowerCase()
        var matches = []
        for (var i = 0; i < events.length; i++)
            if (!normalized || eventSearchText(events[i]).indexOf(normalized) !== -1) matches.push(events[i])
        filteredEvents = matches
        if (resetPage) activityPage = 0
        updateActivityPage()
    }

    function runCommand(command) {
        if (command.view !== undefined) selectView(command.view)
        else if (command.setting) { palette.close(); openSetting(command.setting) }
        else if (command.action) { palette.close(); sendAction(command.action, command) }
    }

    onSnapshotChanged: { buildCommands(); rebuildActivityEvents(false) }
    onActivityQueryChanged: rebuildActivityEvents(true)
    onActivityPageChanged: updateActivityPage()
    onActivityPageSizeChanged: updateActivityPage()
    Component.onCompleted: { buildCommands(); rebuildActivityEvents(true); refresh() }
    Component.onDestruction: {
        stateRequestWatchdog.stop()
        if (stateRequest) {
            stateRequest.onreadystatechange = null
            stateRequest.abort()
        }
    }

    Timer { interval: 30000; repeat: true; running: true; onTriggered: root.refresh() }
    Timer { id: stateRequestWatchdog; interval: 15000; repeat: false; onTriggered: root.cancelStateRequest() }
    Shortcut { sequence: "Ctrl+K"; onActivated: palette.open() }
    Shortcut { sequence: "F8"; onActivated: palette.open() }

    header: ToolBar {
        background: Rectangle { color: "#0b1017"; border.color: "#202a39" }
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20
            Label { text: "AgentOS <font color='#8b5cf6'>Workspace</font>"; textFormat: Text.RichText; font.pixelSize: 18; font.bold: true; color: "#f4f6fa" }
            Label { text: root.field(root.snapshot.system, "environment", "unknown"); color: "#7f8a9c"; Layout.leftMargin: 14 }
            Item { Layout.fillWidth: true }
            Label { text: root.field(root.snapshot.health, "status", "unknown"); color: root.statusColor(root.field(root.snapshot.health, "status", "")) }
            Button { text: root.loading ? "Refreshing…" : "Refresh"; enabled: !root.loading; onClicked: root.refresh() }
            Button { text: "Ctrl+K  Commands"; onClicked: palette.open() }
        }
    }

    RowLayout {
        anchors.fill: parent; spacing: 0
        Rectangle {
            Layout.fillHeight: true; Layout.preferredWidth: 220; color: "#090d14"; border.color: "#202a39"
            ColumnLayout {
                anchors.fill: parent; anchors.margins: 16; spacing: 8
                Label { text: "AGENTOS"; color: "#7f8a9c"; font.pixelSize: 11 }
                Repeater {
                    model: ["Workspace", "Agents", "Activity", "System"]
                    delegate: Button {
                        required property var modelData; required property int index
                        text: modelData; Layout.fillWidth: true; highlighted: root.currentView === index
                        onClicked: root.selectView(index)
                    }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: "#202a39"; Layout.topMargin: 6 }
                Label { text: "PROJECTS"; color: "#7f8a9c"; font.pixelSize: 11; Layout.topMargin: 4 }
                Repeater {
                    model: root.field(root.snapshot, "projects", [])
                    delegate: Label { required property var modelData; text: "• " + root.field(modelData, "name", "unnamed"); color: "#d9deea"; elide: Text.ElideRight; Layout.fillWidth: true }
                }
                Item { Layout.fillHeight: true }
                Label { text: root.errorText || "API  /v1/state"; color: root.errorText ? "#ff8c9a" : "#546176"; font.family: "monospace"; wrapMode: Text.Wrap; Layout.fillWidth: true }
            }
        }

        StackLayout {
            id: pages; Layout.fillWidth: true; Layout.fillHeight: true; currentIndex: root.currentView

            ScrollView {
                clip: true
                ColumnLayout {
                    width: Math.max(600, root.width - 270); spacing: 16; anchors.margins: 24
                    Label { text: "Workspace"; color: "#f4f6fa"; font.pixelSize: 30; font.bold: true }
                    Label { text: "Persistent sessions and human attention in one place."; color: "#7f8a9c"; Layout.fillWidth: true }
                    GridLayout { Layout.fillWidth: true; columns: root.width < 1200 ? 2 : 4; columnSpacing: 12; rowSpacing: 12
                        InfoCard { label: "Sessions"; value: root.field(root.snapshot, "sessions", []).length }
                        InfoCard { label: "Attention"; value: root.field(root.snapshot, "attention", []).length; accent: "#ffb84d" }
                        InfoCard { label: "Update channel"; value: root.field(root.snapshot.updates, "channel", "unknown") }
                        InfoCard { label: "Uptime"; value: root.field(root.snapshot, "uptime", "unknown") }
                    }
                    RowLayout { Layout.fillWidth: true
                        Panel { title: "Attention inbox"; Layout.fillWidth: true
                            Repeater { model: root.field(root.snapshot, "attention", []); delegate: Label { required property var modelData; text: "• " + root.field(modelData, "text", "Attention required"); color: root.statusColor(root.field(modelData, "level", "attention")); wrapMode: Text.Wrap; Layout.fillWidth: true } }
                            Label { text: root.field(root.snapshot, "attention", []).length ? "" : "Nothing needs your attention."; color: "#7f8a9c" }
                        }
                        Panel { title: "Active sessions"; Layout.fillWidth: true
                            Repeater { model: root.field(root.snapshot, "sessions", []); delegate: Label { required property var modelData; text: root.field(modelData, "agent", "agent") + " · " + root.field(modelData, "status", "unknown"); color: root.statusColor(root.field(modelData, "status", "")); Layout.fillWidth: true } }
                            Label { text: root.field(root.snapshot, "sessions", []).length ? "" : "No active sessions."; color: "#7f8a9c" }
                        }
                    }
                    Panel { title: "System"; Layout.fillWidth: true
                        RowLayout { Layout.fillWidth: true
                            Label { text: root.field(root.snapshot.system, "hostname", "unknown") + " · " + root.field(root.snapshot.system, "virtualization", "none"); color: "#d9deea"; Layout.fillWidth: true }
                            Button { text: "Open System"; onClicked: root.selectView(3) }
                        }
                    }
                }
            }

            ScrollView {
                clip: true
                ColumnLayout {
                    width: Math.max(600, root.width - 270); spacing: 16; anchors.margins: 24
                    Label { text: "Agents"; color: "#f4f6fa"; font.pixelSize: 30; font.bold: true }
                    Label { text: "Persistent sessions, lifecycle state, tools and local models."; color: "#7f8a9c"; Layout.fillWidth: true }
                    Panel { title: "Agent catalog"; Layout.fillWidth: true
                        Repeater { model: root.field(root.snapshot, "agents", []); delegate: Rectangle {
                            required property var modelData; Layout.fillWidth: true; implicitHeight: 54; color: "#090d14"; border.color: "#202a39"
                            RowLayout { anchors.fill: parent; anchors.margins: 10
                                Label { text: root.field(modelData, "name", "Agent"); color: "#f4f6fa"; Layout.fillWidth: true }
                                Label { text: root.field(modelData, "enabled", false) ? "enabled" : "disabled"; color: root.field(modelData, "enabled", false) ? "#3ddc84" : "#7f8a9c" }
                                Label { text: root.field(modelData, "session_count", 0) + " sessions"; color: "#7f8a9c" }
                                Button { text: "Start"; enabled: root.field(modelData, "enabled", false); onClicked: root.sendAction("agent-start", {agent: root.field(modelData, "id", ""), project: root.firstProject()}) }
                            }
                        }}
                    }
                    Panel { title: "Sessions"; Layout.fillWidth: true
                        Repeater { model: root.field(root.snapshot, "sessions", []); delegate: Rectangle {
                            required property var modelData; Layout.fillWidth: true; implicitHeight: 92; color: "#090d14"; border.color: "#202a39"
                            ColumnLayout { anchors.fill: parent; anchors.margins: 10; spacing: 5
                                RowLayout { Layout.fillWidth: true
                                    Label { text: root.field(modelData, "agent", "agent"); color: "#f4f6fa"; font.bold: true; Layout.fillWidth: true }
                                    Label { text: root.field(modelData, "status", "unknown"); color: root.statusColor(root.field(modelData, "status", "")) }
                                    Label { text: root.field(modelData, "elapsed", ""); color: "#7f8a9c" }
                                }
                                Label { text: root.field(modelData, "project", "workspace") + " · " + root.field(modelData, "status_source", "process") + " · PID " + root.field(modelData, "pid", 0); color: "#7f8a9c"; Layout.fillWidth: true; elide: Text.ElideRight }
                                RowLayout { Layout.fillWidth: true
                                    Button { text: "Attach"; onClicked: root.sendAction("agent-attach", {agent: root.field(modelData, "agent", ""), project: root.field(modelData, "project", "")}) }
                                    Button { text: "Logs"; onClicked: root.sendAction("agent-logs", {agent: root.field(modelData, "agent", ""), project: root.field(modelData, "project", ""), session: root.field(modelData, "id", "")}) }
                                    Button { text: "Stop"; onClicked: root.sendAction("agent-stop", {agent: root.field(modelData, "agent", ""), project: root.field(modelData, "project", ""), session: root.field(modelData, "id", ""), pid: root.field(modelData, "pid", 0)}) }
                                    Item { Layout.fillWidth: true }
                                }
                            }
                        }}
                        Label { text: root.field(root.snapshot, "sessions", []).length ? "" : "No active sessions."; color: "#7f8a9c" }
                    }
                    RowLayout { Layout.fillWidth: true
                        Panel { title: "Developer tools"; Layout.fillWidth: true
                            Repeater { model: root.field(root.snapshot, "developer_tools", []); delegate: RowLayout { required property var modelData; Layout.fillWidth: true
                                Label { text: root.field(modelData, "name", "Tool") + " · " + root.field(modelData, "command", ""); color: "#d9deea"; Layout.fillWidth: true; elide: Text.ElideRight }
                                Label { text: root.field(modelData, "installed", false) ? "installed" : "optional"; color: root.field(modelData, "installed", false) ? "#3ddc84" : "#7f8a9c" }
                                Button { text: root.field(modelData, "installed", false) ? "Open" : "Install"; onClicked: root.sendAction((root.field(modelData, "installed", false) ? "open-" : "install-") + root.field(modelData, "id", ""), {}) }
                            }}
                        }
                        Panel { title: "Loaded models"; Layout.fillWidth: true
                            Repeater { model: root.field(root.snapshot, "models", []); delegate: Label { required property var modelData; text: root.field(modelData, "name", "model") + " · " + root.field(modelData, "processor", "unknown"); color: "#d9deea"; Layout.fillWidth: true } }
                            Label { text: root.field(root.snapshot, "models", []).length ? "" : "No local models loaded."; color: "#7f8a9c" }
                        }
                    }
                }
            }

            ScrollView {
                clip: true
                ColumnLayout {
                    width: Math.max(600, root.width - 270); spacing: 16; anchors.margins: 24
                    Label { text: "Activity"; color: "#f4f6fa"; font.pixelSize: 30; font.bold: true }
                    Label { text: "Persistent lifecycle, tool, approval and file-change events."; color: "#7f8a9c"; Layout.fillWidth: true }
                    Panel { title: "Runtime events"; Layout.fillWidth: true
                        RowLayout { Layout.fillWidth: true; spacing: 8
                            TextField { id: activitySearch; placeholderText: "Search events by kind, agent, project or message…"; Layout.fillWidth: true; onTextChanged: root.activityQuery = text }
                            Button { text: "Clear"; visible: activitySearch.text.length > 0; onClicked: activitySearch.clear() }
                            Label { text: root.filteredEvents.length + " events"; color: "#7f8a9c" }
                        }
                        Repeater { model: root.activityPageEvents; delegate: Rectangle {
                            required property var modelData; required property int index
                            Layout.fillWidth: true; implicitHeight: 64; color: index % 2 ? "#0a0f17" : "#090d14"; border.color: "#202a39"
                            GridLayout { anchors.fill: parent; anchors.margins: 9; columns: 3; columnSpacing: 12
                                Label { text: root.field(modelData, "kind", "event"); color: "#8b5cf6"; font.pixelSize: 11; font.bold: true; Layout.minimumWidth: 112; Layout.preferredWidth: 112; Layout.maximumWidth: 112; elide: Text.ElideRight }
                                ColumnLayout { Layout.fillWidth: true; Layout.minimumWidth: 0; spacing: 3
                                    Label { text: root.field(modelData, "text", ""); color: "#d9deea"; Layout.fillWidth: true; Layout.minimumWidth: 0; elide: Text.ElideRight }
                                    Label { text: root.field(modelData, "agent", "") + (root.field(modelData, "project", "") ? " · " + root.field(modelData, "project", "") : ""); color: "#7f8a9c"; Layout.fillWidth: true; Layout.minimumWidth: 0; elide: Text.ElideRight }
                                }
                                Label { text: root.field(modelData, "time", ""); color: "#7f8a9c"; Layout.minimumWidth: 126; Layout.preferredWidth: 126; Layout.maximumWidth: 126; horizontalAlignment: Text.AlignRight; elide: Text.ElideLeft }
                            }
                        }}
                        Label { text: root.filteredEvents.length ? "" : (root.activityQuery ? "No events match this search." : "No runtime events yet."); color: "#7f8a9c" }
                        RowLayout { Layout.fillWidth: true; spacing: 8
                            Label {
                                text: root.filteredEvents.length ? "Showing " + (root.activityPage * root.activityPageSize + 1) + "–" + Math.min((root.activityPage + 1) * root.activityPageSize, root.filteredEvents.length) + " of " + root.filteredEvents.length : "No matching events"
                                color: "#7f8a9c"; Layout.fillWidth: true
                            }
                            Button { text: "Previous"; enabled: root.activityPage > 0; onClicked: root.activityPage-- }
                            Label { text: "Page " + (root.activityPage + 1) + " / " + root.activityPageCount; color: "#d9deea" }
                            Button { text: "Next"; enabled: root.activityPage + 1 < root.activityPageCount; onClicked: root.activityPage++ }
                        }
                    }
                    Panel { title: "Project activity"; Layout.fillWidth: true
                        Repeater { model: root.field(root.snapshot, "projects", []); delegate: ColumnLayout { required property var modelData; Layout.fillWidth: true; spacing: 4
                            Label { text: root.field(modelData, "name", "project") + " · " + root.field(modelData, "branch", "unknown"); color: "#f4f6fa" }
                            Label { text: root.field(modelData, "last_activity", "No recent activity"); color: "#7f8a9c" }
                            Repeater { model: root.field(modelData, "commits", []); delegate: Label { required property var modelData; text: root.field(modelData, "SHA", root.field(modelData, "sha", "")) + " · " + root.field(modelData, "Subject", root.field(modelData, "subject", "")); color: "#d9deea"; Layout.fillWidth: true; elide: Text.ElideRight } }
                        }}
                    }
                }
            }

            ScrollView {
                clip: true
                ColumnLayout {
                    width: Math.max(600, root.width - 270); spacing: 16; anchors.margins: 24
                    Label { text: "System"; color: "#f4f6fa"; font.pixelSize: 30; font.bold: true }
                    Label { text: "Updates, hardware readiness, recovery, support and native KDE settings."; color: "#7f8a9c"; Layout.fillWidth: true; wrapMode: Text.Wrap }
                    Label { visible: root.loading; text: "Loading system information…"; color: "#7f8a9c" }
                    Label { visible: root.errorText !== ""; text: root.errorText; color: "#ff8c9a"; wrapMode: Text.Wrap; Layout.fillWidth: true }
                    Panel { title: "Start here"; Layout.fillWidth: true
                        Label { text: "1. Review Health and Hardware readiness.  2. Check Update Center.  3. Use Recovery Center before risky changes."; color: "#d9deea"; wrapMode: Text.Wrap; Layout.fillWidth: true }
                        Label { text: "Actions that change the machine open a visible confirmation flow. Firmware, reboot, and rollback stay separate."; color: "#7f8a9c"; wrapMode: Text.Wrap; Layout.fillWidth: true }
                    }
                    RowLayout { Layout.fillWidth: true
                        Panel { title: "Environment"; Layout.fillWidth: true
                            Label { text: "Role  ·  " + root.field(root.snapshot.system, "environment", "unknown"); color: "#d9deea" }
                            Label { text: "Virtualization  ·  " + root.field(root.snapshot.system, "virtualization", "unknown"); color: "#d9deea" }
                            Label { text: "Hostname  ·  " + root.field(root.snapshot.system, "hostname", root.snapshot.host); color: "#d9deea" }
                        }
                        Panel { title: "Health"; Layout.fillWidth: true
                            Label { text: "Status  ·  " + root.field(root.snapshot.health, "status", "unknown"); color: root.statusColor(root.field(root.snapshot.health, "status", "")) }
                            Label { text: "Failed units  ·  " + root.field(root.snapshot.health, "failed_units", 0); color: root.field(root.snapshot.health, "failed_units", 0) ? "#ff6474" : "#d9deea" }
                            Label { text: "CPU temp  ·  " + root.field(root.snapshot.health, "cpu_temp", "n/a") + "   Btrfs errors  ·  " + root.field(root.snapshot.health, "btrfs_errors", 0); color: "#d9deea" }
                        }
                    }
                    Panel { title: "System settings"; Layout.fillWidth: true
                        Label { text: root.field(root.snapshot.system, "environment", "") === "vps" ? "Headless VPS: controls appear when a graphical KDE session is available." : "KDE settings retain normal Linux/Polkit authorization."; color: "#7f8a9c"; wrapMode: Text.Wrap; Layout.fillWidth: true }
                        Flow { Layout.fillWidth: true; spacing: 8
                            Repeater { model: root.field(root.snapshot.system, "settings", []); delegate: Button { required property var modelData; text: root.field(modelData, "name", "Settings") + (root.field(modelData, "available", false) ? "" : " · unavailable"); enabled: root.field(modelData, "available", false); onClicked: root.openSetting(modelData) } }
                        }
                    }
                    RowLayout { Layout.fillWidth: true
                        Panel { title: "Update Center"; Layout.fillWidth: true
                            Label { text: "Status  ·  " + root.field(root.snapshot.updates, "status", "not-checked"); color: root.statusColor(root.field(root.snapshot.updates, "status", "")); font.bold: true }
                            Label { text: "Channel  ·  " + root.field(root.snapshot.updates, "channel", "unknown"); color: "#d9deea" }
                            Label { text: "Installed  ·  " + root.field(root.snapshot.updates, "current_version", root.field(root.snapshot.updates, "version", "unknown")); color: "#d9deea" }
                            Label { visible: root.field(root.snapshot.updates, "target_version", "") !== ""; text: "Available  ·  " + root.field(root.snapshot.updates, "target_version", ""); color: "#d9deea" }
                            Label { text: "Pending Arch packages  ·  " + root.field(root.snapshot.updates, "arch_pending", 0); color: "#d9deea" }
                            Label { text: "Last check  ·  " + root.field(root.snapshot.updates, "checked_at", "never"); color: "#7f8a9c"; wrapMode: Text.Wrap; Layout.fillWidth: true }
                            Label { text: "Last successful update  ·  " + root.field(root.snapshot.updates, "last_success_at", "never"); color: "#7f8a9c"; wrapMode: Text.Wrap; Layout.fillWidth: true }
                            Label { visible: root.field(root.snapshot.updates, "last_failure", "") !== ""; text: "Problem  ·  " + root.field(root.snapshot.updates, "last_failure", ""); color: "#ff8c9a"; wrapMode: Text.Wrap; Layout.fillWidth: true }
                            Label { visible: root.field(root.snapshot.updates, "snapshot_id", "") !== ""; text: "Recovery point  ·  " + root.field(root.snapshot.updates, "snapshot_id", "") + "   Migration  ·  " + root.field(root.snapshot.updates, "migration_status", "unknown"); color: "#7f8a9c"; wrapMode: Text.Wrap; Layout.fillWidth: true }
                            Label { visible: root.field(root.snapshot.updates, "reboot_required", false); text: "Restart manually when convenient. AgentOS will not restart automatically."; color: "#ffb84d"; wrapMode: Text.Wrap; Layout.fillWidth: true }
                            RowLayout { Layout.fillWidth: true
                                Button { text: root.field(root.snapshot.updates, "status", "") === "checking" ? "Checking…" : "Check"; enabled: root.field(root.snapshot.updates, "status", "") !== "checking"; onClicked: root.sendAction("update-check", {}) }
                                Button { text: "Update now"; highlighted: true; enabled: ["available", "check-failed", "apply-failed"].indexOf(root.field(root.snapshot.updates, "status", "")) !== -1; onClicked: root.sendAction("update-apply", {}) }
                                Item { Layout.fillWidth: true }
                            }
                        }
                        Panel { id: hardwarePanel; title: "Hardware readiness"; Layout.fillWidth: true
                            property var hardwareState: root.field(root.snapshot, "hardware", {})
                            property var firmwareState: root.field(hardwareState, "firmware", {})
                            Label { text: "Overall  ·  " + root.field(hardwarePanel.hardwareState, "overall", "unavailable"); color: root.statusColor(root.field(hardwarePanel.hardwareState, "overall", "")); font.bold: true }
                            Label { text: "Machine role  ·  " + root.field(hardwarePanel.hardwareState, "role", "unknown"); color: "#d9deea" }
                            Repeater { model: root.field(hardwarePanel.hardwareState, "checks", []); delegate: ColumnLayout { required property var modelData; Layout.fillWidth: true; spacing: 2
                                Label { text: root.hardwareLabel(root.field(modelData, "id", "")) + "  ·  " + root.field(modelData, "status", "unavailable"); color: root.statusColor(root.field(modelData, "status", "")); font.bold: true }
                                Label { text: root.field(modelData, "detail", "No detail available"); color: "#7f8a9c"; wrapMode: Text.Wrap; Layout.fillWidth: true }
                            }}
                            Label { visible: root.field(hardwarePanel.hardwareState, "checks", []).length === 0; text: "Hardware readiness is unavailable."; color: "#7f8a9c" }
                            Label { text: "Firmware  ·  " + root.field(hardwarePanel.firmwareState, "status", "unavailable") + "  ·  " + root.field(hardwarePanel.firmwareState, "detail", "fwupd is optional"); color: root.statusColor(root.field(hardwarePanel.firmwareState, "status", "")); wrapMode: Text.Wrap; Layout.fillWidth: true }
                            Flow { Layout.fillWidth: true; spacing: 8
                                Button { text: "Enable firmware support"; visible: root.maintenanceActionAvailable("firmware-enable"); activeFocusOnTab: true; onClicked: root.sendAction("firmware-enable", {}) }
                                Button { text: "Check firmware"; visible: root.maintenanceActionAvailable("firmware-check"); activeFocusOnTab: true; onClicked: root.sendAction("firmware-check", {}) }
                                Button { text: "Apply firmware updates"; visible: root.maintenanceActionAvailable("firmware-apply"); enabled: root.field(hardwarePanel.firmwareState, "updates", 0) > 0; activeFocusOnTab: true; onClicked: root.sendAction("firmware-apply", {}) }
                            }
                        }
                    }
                    Panel { id: recoveryPanel; title: "Recovery Center"; Layout.fillWidth: true
                        property var recoveryState: root.field(root.snapshot, "recovery", {})
                        property var recommendedPoint: root.recommendedRecoveryPoint()
                        Label { text: "Status  ·  " + root.field(recoveryPanel.recoveryState, "status", "unavailable"); color: root.statusColor(root.field(recoveryPanel.recoveryState, "status", "")); font.bold: true }
                        Label { text: "Current root  ·  " + root.field(recoveryPanel.recoveryState, "current_root", "unknown") + (root.field(recoveryPanel.recoveryState, "current_rollback", false) ? " · rollback active" : ""); color: "#d9deea"; wrapMode: Text.Wrap; Layout.fillWidth: true }
                        Label { text: "Next boot  ·  " + root.field(recoveryPanel.recoveryState, "next_boot", "unknown"); color: root.field(recoveryPanel.recoveryState, "next_boot", "") === "rollback-once" ? "#ffb84d" : "#d9deea" }
                        Label { visible: root.field(recoveryPanel.recoveryState, "staged", null) !== null; text: "Staged from  ·  " + root.field(root.field(recoveryPanel.recoveryState, "staged", {}), "source_id", "unknown"); color: "#ffb84d"; wrapMode: Text.Wrap; Layout.fillWidth: true }
                        Label { text: root.field(recoveryPanel.recoveryState, "next_boot", "") === "rollback-once" ? "Only the next boot uses this recovery point. Reboot remains a separate decision; a later boot returns to normal." : "Boot-safe points include a verified matching kernel and initramfs bundle. Root-only points cannot be staged here."; color: "#7f8a9c"; wrapMode: Text.Wrap; Layout.fillWidth: true }
                        Repeater { model: root.field(recoveryPanel.recoveryState, "points", []); delegate: RowLayout { required property var modelData; Layout.fillWidth: true
                            Label { text: root.field(modelData, "id", "unknown") + (recoveryPanel.recommendedPoint && root.field(recoveryPanel.recommendedPoint, "id", "") === root.field(modelData, "id", "") ? " · recommended" : ""); color: "#d9deea"; Layout.fillWidth: true; elide: Text.ElideRight }
                            Label { text: root.field(modelData, "boot_safe", false) ? "boot-safe" : "root-only"; color: root.field(modelData, "boot_safe", false) ? "#3ddc84" : "#7f8a9c" }
                            Button { text: "Stage for next boot"; enabled: root.field(modelData, "boot_safe", false) && root.maintenanceActionAvailable("recovery-stage"); onClicked: root.sendAction("recovery-stage", { recovery_point_id: root.field(modelData, "id", "") }) }
                        }}
                        Label { visible: root.field(recoveryPanel.recoveryState, "points", []).length === 0; text: "No recovery points are available yet."; color: "#7f8a9c" }
                        RowLayout { Layout.fillWidth: true
                            Button { text: "Cancel staged rollback"; enabled: root.maintenanceActionAvailable("recovery-cancel"); onClicked: root.sendAction("recovery-cancel", {}) }
                            Item { Layout.fillWidth: true }
                            Button { text: "Doctor"; onClicked: root.sendAction("doctor", {}) }
                            Button { text: "Snapshot"; onClicked: root.sendAction("snapshot", {}) }
                        }
                    }
                    RowLayout { Layout.fillWidth: true
                        Panel { title: "Connectivity"; Layout.fillWidth: true
                            Label { text: "SSH  ·  " + (root.field(root.snapshot.health, "ssh", false) ? "online" : "offline"); color: root.field(root.snapshot.health, "ssh", false) ? "#3ddc84" : "#ff6474" }
                            Label { text: "Tailscale  ·  " + root.field(root.snapshot.health, "tailscale", "unknown"); color: "#d9deea" }
                            Label { text: "KRDP  ·  " + (root.field(root.snapshot.health, "krdp", false) ? "online" : "offline"); color: root.field(root.snapshot.health, "krdp", false) ? "#3ddc84" : "#ff6474" }
                        }
                        Panel { title: "Support & privacy"; Layout.fillWidth: true
                            Label { text: "Support reports stay local and redact secrets. Review the file before sharing it."; color: "#7f8a9c"; wrapMode: Text.Wrap; Layout.fillWidth: true }
                            Label { text: "Telemetry is disabled by default; creating a report never uploads it."; color: "#7f8a9c"; wrapMode: Text.Wrap; Layout.fillWidth: true }
                            RowLayout { Layout.fillWidth: true
                                Button { text: "Run Doctor"; activeFocusOnTab: true; onClicked: root.sendAction("doctor", {}) }
                                Button { text: "Create local report"; activeFocusOnTab: true; onClicked: root.sendAction("support", {}) }
                                Item { Layout.fillWidth: true }
                            }
                        }
                    }
                }
            }
        }
    }

    Popup {
        id: palette; modal: true; focus: true; width: Math.min(root.width - 48, 720); height: Math.min(root.height - 96, 520)
        anchors.centerIn: Overlay.overlay; closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        background: Rectangle { color: "#0c1119"; border.color: "#303a4b"; radius: 12 }
        onOpened: search.forceActiveFocus()
        ColumnLayout { anchors.fill: parent; anchors.margins: 14; spacing: 10
            Label { text: "Command palette"; color: "#f4f6fa"; font.pixelSize: 18; font.bold: true }
            TextField { id: search; placeholderText: "Search views, projects, agents or commands…"; Layout.fillWidth: true; onTextChanged: root.filterCommands(text) }
            ListView { Layout.fillWidth: true; Layout.fillHeight: true; clip: true; model: root.filteredCommands
                delegate: Button { required property var modelData; width: ListView.view.width; text: modelData.label; onClicked: root.runCommand(modelData) }
            }
        }
    }

    component InfoCard: Rectangle {
        property string label: ""; property var value: ""; property color accent: "#8b5cf6"
        Layout.fillWidth: true; Layout.preferredHeight: 84; color: "#0b1017"; border.color: "#202a39"; radius: 8
        ColumnLayout { anchors.fill: parent; anchors.margins: 14; spacing: 5
            Label { text: label; color: "#7f8a9c"; Layout.fillWidth: true }
            Label { text: value; color: accent; font.pixelSize: 20; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
        }
    }

    component Panel: Rectangle {
        property string title: ""; default property alias content: panelColumn.data
        Layout.fillWidth: true; color: "#0b1017"; border.color: "#202a39"; radius: 8
        implicitHeight: panelColumn.implicitHeight + 28
        ColumnLayout { id: panelColumn; anchors.fill: parent; anchors.margins: 14; spacing: 8
            Label { text: title; color: "#f4f6fa"; font.bold: true }
        }
    }
}
