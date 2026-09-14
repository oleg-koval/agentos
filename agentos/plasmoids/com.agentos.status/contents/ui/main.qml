import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PC3

PlasmoidItem {
    id: root
    implicitWidth: row.implicitWidth + 18
    implicitHeight: 28
    preferredRepresentation: fullRepresentation
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: statusText + ". Open Update Center"

    property string updateStatus: "not-checked"
    property string targetVersion: ""
    property string statusText: {
        if (updateStatus === "available") return targetVersion ? "Update " + targetVersion + " available" : "Update available"
        if (updateStatus === "checking") return "Checking for updates"
        if (updateStatus === "check-failed" || updateStatus === "apply-failed") return "Update needs attention"
        if (updateStatus === "reboot-required") return "Restart required"
        if (updateStatus === "up-to-date" || updateStatus === "succeeded") return "Up to date"
        if (updateStatus === "unavailable") return "Update status unavailable"
        return "Updates not checked"
    }
    property color updateColor: {
        if (updateStatus === "check-failed" || updateStatus === "apply-failed" || updateStatus === "unavailable") return "#ff6474"
        if (updateStatus === "checking" || updateStatus === "available" || updateStatus === "reboot-required") return "#ffb84d"
        if (updateStatus === "up-to-date" || updateStatus === "succeeded") return "#34d17b"
        return "#7f8a9c"
    }

    function refresh() {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status < 200 || xhr.status >= 300) { updateStatus = "unavailable"; return }
            try {
                var state = JSON.parse(xhr.responseText)
                updateStatus = state.updates && state.updates.status ? state.updates.status : "not-checked"
                targetVersion = state.updates && state.updates.target_version ? state.updates.target_version : ""
            } catch (error) { updateStatus = "unavailable" }
        }
        xhr.open("GET", "http://127.0.0.1:4787/v1/state", true)
        xhr.send()
    }

    function openUpdateCenter() {
        var xhr = new XMLHttpRequest()
        xhr.open("POST", "http://127.0.0.1:4787/v1/action", true)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.send(JSON.stringify({name: "update-center-open"}))
    }

    Keys.onReturnPressed: openUpdateCenter()
    Keys.onSpacePressed: openUpdateCenter()
    Component.onCompleted: refresh()
    Timer { interval: 30000; repeat: true; running: true; onTriggered: root.refresh() }
    TapHandler { onTapped: root.openUpdateCenter() }

    fullRepresentation: RowLayout {
        id: row
        spacing: 8
        PC3.Label { text: "▲"; color: "#9b7cff"; font.bold: true }
        PC3.Label { text: "AgentOS"; font.bold: true }
        Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 16; color: "#303745" }
        Rectangle { Layout.preferredWidth: 8; Layout.preferredHeight: 8; radius: 4; color: root.updateColor }
        PC3.Label { text: root.statusText; color: root.updateColor; font.pixelSize: 11 }
    }
}
