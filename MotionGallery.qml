import QtQuick
import QtQuick.Controls
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Grid of motion stills saved by motiond.py (last 24h). Local files only.
FocusScope {
    id: root
    property url selectedSource: ""
    signal closed()

    readonly property string helper: Qt.resolvedUrl("motiond.py").toString().replace(/^file:\/\//, "")
    readonly property color foreground: Color.foreground
    property var items: []
    property bool loading: false
    property string listError: ""
    property string statusLine: ""

    function refresh() {
        if (lister.running) return
        loading = true
        listError = ""
        lister.running = true
    }

    Keys.onEscapePressed: function(event) {
        if (selectedSource.toString() !== "") {
            selectedSource = ""
            event.accepted = true
            return
        }
        event.accepted = false
        closed()
    }

    Component.onCompleted: refresh()

    Process {
        id: lister
        command: ["python3", root.helper, "--list"]
        stdout: StdioCollector {
            id: listStdout
        }
        stderr: StdioCollector {
            id: listStderr
        }
        onExited: function(code) {
            root.loading = false
            if (code !== 0) {
                root.listError = "Could not list motion captures."
                root.items = []
                return
            }
            try {
                var parsed = JSON.parse(listStdout.text || "[]")
                if (!Array.isArray(parsed)) throw new Error()
                root.items = parsed
            } catch (error) {
                root.listError = "Motion list was unreadable."
                root.items = []
            }
        }
    }

    Process {
        id: statusReader
        command: [
            "python3", "-c",
            "import json,pathlib;"
            + "p=pathlib.Path.home()/'.local/share/rtsp-camera/motion/.status.json';"
            + "print(json.dumps(json.loads(p.read_text()) if p.exists() else {}))"
        ]
        stdout: StdioCollector { id: statusStdout }
        onExited: function(code) {
            if (code !== 0) {
                root.statusLine = "Listener status unavailable."
                return
            }
            try {
                var s = JSON.parse(statusStdout.text || "{}")
                if (s.listening === false && s.lastError) {
                    root.statusLine = "Listener offline · " + s.lastError
                } else if (s.listening === true) {
                    root.statusLine = "Listener on" + (s.camera ? " · " + s.camera : "")
                } else {
                    root.statusLine = s.enabled === false ? "Motion capture disabled" : "Listener starting…"
                }
            } catch (error) {
                root.statusLine = ""
            }
        }
    }

    Timer {
        interval: 15000
        running: root.visible && !root.selectedSource.toString()
        repeat: true
        onTriggered: {
            root.refresh()
            statusReader.running = false
            statusReader.running = true
        }
    }

    onVisibleChanged: {
        if (root.visible) {
            root.refresh()
            statusReader.running = false
            statusReader.running = true
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Controls.Button {
                text: "← Live"
                leftPadding: 14
                rightPadding: 14
                topPadding: 7
                bottomPadding: 7
                hoverEnabled: true
                background: Rectangle {
                    radius: height / 2
                    color: parent.hovered
                        ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.10)
                        : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.06)
                    border.width: 1
                    border.color: Qt.rgba(Color.popups.border.r, Color.popups.border.g, Color.popups.border.b, 0.55)
                }
                contentItem: Text {
                    text: parent.text
                    color: parent.hovered ? Color.accent : Color.popups.text
                    font.pixelSize: Style.font.caption
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                Accessible.name: "Back to live view"
                PanelToolTip {
                    visible: parent.hovered
                    text: "Live view"
                    fontSize: Style.font.caption
                }
                onClicked: root.closed()
                PointerArea {}
            }
            Label {
                text: "Motion captures · last 24h"
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            Label {
                text: root.items.length + (root.items.length === 1 ? " still" : " stills")
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                opacity: 0.7
            }
            Controls.Button {
                text: root.loading ? "Refreshing…" : "Refresh"
                enabled: !root.loading
                leftPadding: 14
                rightPadding: 14
                topPadding: 7
                bottomPadding: 7
                hoverEnabled: true
                background: Rectangle {
                    radius: height / 2
                    color: parent.hovered
                        ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.28)
                        : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.06)
                    border.width: 1
                    border.color: Qt.rgba(Color.popups.border.r, Color.popups.border.g, Color.popups.border.b, 0.55)
                }
                contentItem: Text {
                    text: parent.text
                    color: parent.hovered ? Color.accent : Color.popups.text
                    font.pixelSize: Style.font.caption
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                onClicked: root.refresh()
                PanelToolTip {
                    visible: parent.hovered
                    text: "Reload stills"
                    fontSize: Style.font.caption
                }
                PointerArea {}
            }
        }

        Label {
            Layout.fillWidth: true
            visible: root.statusLine !== "" || root.listError !== ""
            text: root.listError || root.statusLine
            color: root.listError ? "#f38ba8" : root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            opacity: 0.9
        }

        Label {
            Layout.fillWidth: true
            visible: !root.loading && !root.listError && root.items.length === 0
            text: "No motion stills yet. The listener saves a frame when the camera reports motion; files are wiped after 24 hours."
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            opacity: 0.75
        }

        Controls.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth
            Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff

            GridView {
                id: grid
                width: parent ? parent.width : 0
                model: root.items
                cellWidth: Math.max(140, Math.floor((width - 8) / Math.max(1, Math.floor(width / 180))))
                cellHeight: cellWidth * 0.72 + 28
                interactive: true
                clip: true

                delegate: Item {
                    required property var modelData
                    width: grid.cellWidth
                    height: grid.cellHeight

                    Column {
                        anchors.fill: parent
                        anchors.margins: 4
                        spacing: 4

                            Rectangle {
                                width: parent.width
                                height: parent.height - 24
                                radius: 10
                                color: "#080b10"
                                border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.7)
                                border.width: 1
                                clip: true

                            Image {
                                anchors.fill: parent
                                anchors.margins: 1
                                source: "file://" + modelData.path
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: false
                                sourceSize.width: 360
                                sourceSize.height: 240
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.selectedSource = "file://" + modelData.path
                            }
                        }

                        Text {
                            width: parent.width
                            text: (modelData.date ? modelData.date + "  " : "") + (modelData.time || modelData.name)
                            color: root.foreground
                            font.pixelSize: 11
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignHCenter
                            opacity: 0.9
                        }
                    }
                }
            }
        }
    }

    // Full-size preview
    Rectangle {
        id: preview
        visible: root.selectedSource.toString() !== ""
        anchors.fill: parent
        color: "#f2080b10"
        radius: 10
        z: 10

        MouseArea {
            anchors.fill: parent
            onClicked: root.selectedSource = ""
        }

        Image {
            anchors.fill: parent
            anchors.margins: 24
            source: root.selectedSource
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: false
        }

        Controls.Button {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: 12
            text: "✕"
            z: 11
            leftPadding: 12
            rightPadding: 12
            hoverEnabled: true
            background: Rectangle {
                radius: height / 2
                color: parent.hovered
                    ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.16)
                    : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.10)
                border.width: 1
                border.color: Qt.rgba(Color.popups.border.r, Color.popups.border.g, Color.popups.border.b, 0.5)
            }
            contentItem: Text {
                text: parent.text
                color: parent.hovered ? Color.accent : Color.popups.text
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
            onClicked: root.selectedSource = ""
            PointerArea {}
        }
    }
}
