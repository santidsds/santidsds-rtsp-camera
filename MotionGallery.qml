import QtQuick
import QtQuick.Controls
import QtQuick.Controls as Controls
import QtQuick.Layouts
import QtQuick.Effects
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Grid of motion stills saved by motiond.py (last 24h). Local files only.
FocusScope {
    id: root
    Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
    AppleStyle { id: ui }
    // Index into visibleItems of the still open in the viewer, or -1 for the grid.
    property int selectedIndex: -1
    readonly property url selectedSource: selectedIndex >= 0 && selectedIndex < visibleItems.length
        ? "file://" + visibleItems[selectedIndex].path : ""
    // Camera filter: "" shows every camera.
    property string cameraFilter: ""
    readonly property var cameraOptions: {
        var seen = {}, options = []
        for (var i = 0; i < items.length; i++) {
            var id = items[i].cameraId || ""
            if (seen[id]) continue
            seen[id] = true
            options.push({id: id, name: cameraLabel(items[i])})
        }
        options.sort(function(a, b) { return a.name.localeCompare(b.name) })
        return options
    }
    readonly property string activeFilter: cameraOptions.some(function(o) { return o.id === root.cameraFilter })
        ? cameraFilter : ""
    readonly property var visibleItems: activeFilter === "" ? items
        : items.filter(function(item) { return (item.cameraId || "") === root.activeFilter })
    readonly property bool showCameraNames: cameraOptions.length > 1 && activeFilter === ""
    onActiveFilterChanged: selectedIndex = -1
    property string listenerState: ""
    property string listenerDetails: ""
    readonly property string today: Qt.formatDate(new Date(), "yyyy-MM-dd")
    signal closed()

    // SD clips: a camera whose motion source is DVRIP (XMeye/iCSee) can send the
    // recording around a still. Only the tapped clip is downloaded (sdclip.py).
    property string clipHelper: Qt.resolvedUrl("sdclip.py").toString().replace(/^file:\/\//, "")
    property var clipSources: ({})
    property string clipState: ""   // "", "fetching", "ready", "error"
    property string clipPath: ""
    property string clipError: ""
    property real clipProgress: 0
    property bool clipPartial: false
    property bool clipPending: false  // a new clip waits for a cancelled download to finish stopping
    property string saveState: ""   // "", "saving", "saved", "error"
    readonly property var previewItem: selectedIndex >= 0 && selectedIndex < visibleItems.length
        ? visibleItems[selectedIndex] : null
    readonly property bool clipAvailable: previewItem !== null
        && clipSources[previewItem.cameraId || ""] === "dvrip"
        && /^\d{4}-\d{2}-\d{2}$/.test(String(previewItem.date || ""))
        && /^\d{2}:\d{2}:\d{2}$/.test(String(previewItem.time || ""))
    onSelectedIndexChanged: closeClip()

    function clipErrorText(code) {
        var keys = {"no-recording": "clip.error.noRecording", "login": "clip.error.login",
            "unreachable": "clip.error.unreachable", "timeout": "clip.error.timeout", "busy": "clip.error.busy",
            "empty": "clip.error.empty", "unsupported": "clip.error.unsupported"}
        return strings.t(keys[code] || "clip.error.failed")
    }
    function megabytes(bytes) {
        return strings.t("clip.megabytes").arg(Qt.locale(Commons.I18n.formatLocale).toString(bytes / 1048576, "f", 1))
    }
    function clock(ms) {
        var seconds = Math.max(0, Math.floor(ms / 1000))
        return Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0")
    }
    function playClip() {
        if (!clipAvailable) return
        clipPath = ""; clipError = ""; clipProgress = 0; clipPartial = false; saveState = ""
        clipState = "fetching"
        forceActiveFocus()
        if (clipFetcher.running) clipPending = true
        else startFetch()
    }
    function startFetch() {
        clipFetcher.gotResult = false
        clipFetcher.command = ["python3", clipHelper, "--camera", String(previewItem.cameraId),
            "--at", previewItem.date + " " + previewItem.time]
        clipFetcher.running = true
    }
    // Leaving a clip stops playback and cancels a download (sdclip.py then tells
    // the camera to stop sending, which matters for weak cameras).
    function closeClip() {
        clipPlayer.stop()
        if (clipFetcher.running) clipFetcher.running = false
        clipPending = false
        clipState = ""; clipPath = ""; clipError = ""; clipProgress = 0; clipPartial = false; saveState = ""
    }
    function toggleClip() {
        if (clipState !== "ready") return
        if (clipPlayer.playbackState === MediaPlayer.PlayingState) clipPlayer.pause()
        else {
            if (clipPlayer.mediaStatus === MediaPlayer.EndOfMedia) clipPlayer.setPosition(0)
            clipPlayer.play()
        }
    }
    function saveClip() {
        if (clipState !== "ready" || clipSaver.running || saveState === "saved" || !previewItem) return
        saveState = "saving"
        clipSaver.command = ["python3", clipHelper, "--camera", String(previewItem.cameraId), "--save", clipPath]
        clipSaver.running = true
    }
    function handleClipLine(line) {
        var message
        try { message = JSON.parse(line) } catch (error) { return }
        if (!message || typeof message !== "object" || clipPending) return  // the cancelled download's last words
        if (typeof message.progress === "number") { clipProgress = message.progress; return }
        clipFetcher.gotResult = true
        if (clipState !== "fetching") return  // cancelled meanwhile
        if (message.ok === true && typeof message.path === "string" && message.path !== "") {
            clipPartial = message.partial === true
            clipPath = message.path
            clipState = "ready"
        } else {
            clipError = String(message.error || "failed")
            clipState = "error"
        }
    }

    function step(delta) {
        if (selectedIndex < 0 || visibleItems.length === 0) return
        selectedIndex = Math.max(0, Math.min(visibleItems.length - 1, selectedIndex + delta))
    }
    function cameraLabel(item) {
        return String(item.cameraName || "").slice(0, 64) || strings.t("motion.unknownCamera")
    }
    // Reduce daemon status (per-camera or the older flat format) to a chip.
    function summarizeStatus(s) {
        if (s.enabled === false) return {state: "disabled", line: strings.t("motion.disabled"), details: ""}
        var cameras = s.cameras && typeof s.cameras === "object" ? s.cameras : null
        if (!cameras) {
            if (s.listening === false && s.lastError)
                return {state: "offline", line: strings.t("motion.listenerOffline").arg(String(s.lastError).slice(0, 120)), details: ""}
            if (s.listening === true)
                return {state: "on", line: s.camera ? strings.t("motion.listeningTo").arg(String(s.camera).slice(0, 64))
                    : strings.t("motion.listening"), details: ""}
            return {state: "starting", line: strings.t("motion.starting"), details: ""}
        }
        var entries = Object.keys(cameras).map(function(id) { return cameras[id] || {} })
        if (entries.length === 0) return {state: "starting", line: strings.t("motion.starting"), details: ""}
        var listening = entries.filter(function(c) { return c.listening === true })
        var failing = entries.filter(function(c) { return c.listening !== true && (c.lastError || c.source === "none") })
        var details = entries.map(function(c) {
            var name = String(c.name || "").slice(0, 64) || strings.t("motion.unknownCamera")
            if (c.listening === true) return strings.t("motion.cameraListening").arg(name)
            if (c.source === "none") return strings.t("motion.cameraNoSource").arg(name)
            if (c.lastError) return strings.t("motion.cameraOffline").arg(name).arg(String(c.lastError).slice(0, 80))
            return strings.t("motion.cameraStarting").arg(name)
        }).join("\n")
        if (failing.length > 0) {
            var first = String(failing[0].name || "").slice(0, 64) || strings.t("motion.unknownCamera")
            return {state: listening.length > 0 ? "partial" : "offline",
                line: strings.t("motion.cameraDown").arg(first), details: details}
        }
        if (listening.length === entries.length)
            return {state: "on", line: entries.length === 1
                ? strings.t("motion.listeningTo").arg(String(entries[0].name || "").slice(0, 64))
                : strings.tn("motion.listeningCount", entries.length).arg(Commons.I18n.formatNumber(entries.length)),
                details: details}
        return {state: "starting", line: strings.t("motion.starting"), details: details}
    }
    function dayLabel(item) {
        if (!item.date || item.date === today) return strings.t("motion.today")
        var date = new Date(item.date + "T12:00:00")
        var yesterday = new Date(); yesterday.setDate(yesterday.getDate() - 1)
        if (Qt.formatDate(yesterday, "yyyy-MM-dd") === item.date) return strings.t("motion.yesterday")
        return date.toLocaleDateString(Qt.locale(Commons.I18n.formatLocale), "d MMM")
    }

    readonly property string helper: Qt.resolvedUrl("motiond.py").toString().replace(/^file:\/\//, "")
    readonly property color foreground: Commons.Color.foreground
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
        if (clipState !== "") {
            closeClip()
            event.accepted = true
            return
        }
        if (selectedIndex >= 0) {
            selectedIndex = -1
            event.accepted = true
            return
        }
        event.accepted = false
        closed()
    }
    Keys.onLeftPressed: function(event) { event.accepted = selectedIndex >= 0; step(-1) }
    Keys.onRightPressed: function(event) { event.accepted = selectedIndex >= 0; step(1) }
    Keys.onSpacePressed: function(event) {
        event.accepted = clipState === "ready" || (clipState === "" && clipAvailable)
        if (clipState === "ready") toggleClip()
        else if (clipState === "" && clipAvailable) playClip()
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
                root.listError = strings.t("motion.listError")
                root.items = []
                return
            }
            try {
                var parsed = JSON.parse(listStdout.text || "[]")
                if (!Array.isArray(parsed)) throw new Error()
                root.items = parsed
            } catch (error) {
                root.listError = strings.t("motion.listUnreadable")
                root.items = []
            }
        }
    }

    // The daemon reports status (one source of truth for its data directory).
    Process {
        id: statusReader
        command: ["python3", root.helper, "--status"]
        stdout: StdioCollector { id: statusStdout }
        onExited: function(code) {
            if (code !== 0) {
                root.listenerState = "unknown"
                root.statusLine = strings.t("motion.statusUnavailable")
                root.listenerDetails = ""
                return
            }
            try {
                var status = JSON.parse(statusStdout.text || "{}")
                var sources = {}
                if (status.cameras && typeof status.cameras === "object")
                    for (var id in status.cameras) sources[id] = String((status.cameras[id] || {}).source || "")
                root.clipSources = sources
                var summary = root.summarizeStatus(status)
                root.listenerState = summary.state
                root.statusLine = summary.line
                root.listenerDetails = summary.details
            } catch (error) {
                root.listenerState = ""
                root.statusLine = ""
                root.listenerDetails = ""
            }
        }
    }

    Timer {
        interval: 15000
        running: root.visible && root.selectedIndex < 0
        repeat: true
        onTriggered: {
            root.refresh()
            statusReader.running = false
            statusReader.running = true
        }
    }

    onVisibleChanged: {
        if (!root.visible) root.closeClip()
        if (root.visible) {
            root.refresh()
            statusReader.running = false
            statusReader.running = true
        }
    }

    Process {
        id: clipFetcher
        property bool gotResult: false
        stdout: SplitParser { onRead: function(line) { root.handleClipLine(line) } }
        onExited: function(code) {
            if (root.clipPending) {
                root.clipPending = false
                if (root.clipState === "fetching" && root.clipAvailable) root.startFetch()
                return
            }
            if (root.clipState === "fetching" && !gotResult) {
                root.clipError = "failed"
                root.clipState = "error"
            }
        }
    }
    Process {
        id: clipSaver
        stdout: StdioCollector { id: saveStdout }
        onExited: function(code) {
            try {
                var lines = saveStdout.text.trim().split("\n")
                root.saveState = JSON.parse(lines[lines.length - 1]).ok === true ? "saved" : "error"
            } catch (error) {
                root.saveState = "error"
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 2
            spacing: 10
            ColumnLayout {
                spacing: 1
                MacText {
                    text: strings.t("motion.title")
                    font.pixelSize: ui.largeTitle
                    font.weight: Font.Bold
                }
                MacText {
                    objectName: "motionSubtitle"
                    text: strings.tn("motion.count", root.visibleItems.length).arg(Commons.I18n.formatNumber(root.visibleItems.length))
                        + " · " + strings.t("motion.window")
                    color: ui.secondaryLabel
                    font.pixelSize: ui.callout
                }
            }
            Item { Layout.fillWidth: true }
            Rectangle {
                objectName: "listenerChip"
                visible: root.statusLine !== ""
                Layout.maximumWidth: Math.max(120, root.width * 0.45)
                implicitWidth: chipRow.implicitWidth + 22
                implicitHeight: 26
                radius: height / 2
                color: ui.fill
                HoverHandler { id: chipHover }
                PanelToolTip {
                    visible: chipHover.hovered && root.listenerDetails !== ""
                    text: root.listenerDetails
                    fontSize: Style.font.caption
                }
                RowLayout {
                    id: chipRow
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 12
                    spacing: 7
                    StatusDot {
                        tone: root.listenerState === "on" ? ui.systemGreen
                            : root.listenerState === "offline" ? ui.systemRed
                            : root.listenerState === "starting" || root.listenerState === "partial" ? ui.systemOrange
                            : ui.tertiaryLabel
                        pulsing: root.listenerState === "starting"
                    }
                    MacText {
                        Layout.fillWidth: true
                        text: root.statusLine
                        color: ui.secondaryLabel
                        font.pixelSize: ui.caption
                        font.weight: Font.Medium
                    }
                }
            }
            MacToolbarButton {
                id: refreshButton
                objectName: "motionRefresh"
                glyph: ui.iconRefresh
                tipText: strings.t("motion.refresh")
                enabled: !root.loading
                onClicked: root.refresh()
            }
        }

        // Camera filter: a segmented control for a few cameras, scrolling chips for many.
        MacSegmented {
            id: cameraFilterControl
            objectName: "motionCameraFilter"
            visible: root.cameraOptions.length > 1 && root.cameraOptions.length <= 3
            Layout.maximumWidth: Math.min(implicitWidth, root.width)
            model: [strings.t("motion.all")].concat(root.cameraOptions.map(function(o) { return o.name }))
            autoSelect: false
            currentIndex: root.activeFilter === "" ? 0
                : 1 + root.cameraOptions.findIndex(function(o) { return o.id === root.activeFilter })
            onActivated: function(index) { root.cameraFilter = index === 0 ? "" : root.cameraOptions[index - 1].id }
        }
        Flickable {
            objectName: "motionCameraChips"
            visible: root.cameraOptions.length > 3
            Layout.fillWidth: true
            implicitHeight: ui.controlHeight
            contentWidth: chipsRow.implicitWidth
            boundsBehavior: Flickable.StopAtBounds
            clip: true
            Row {
                id: chipsRow
                spacing: 6
                Repeater {
                    model: [{id: "", name: strings.t("motion.all")}].concat(root.cameraOptions)
                    MacButton {
                        required property var modelData
                        text: modelData.name
                        role: root.activeFilter === modelData.id ? "default" : "normal"
                        onClicked: root.cameraFilter = modelData.id
                    }
                }
            }
        }

        MacText {
            Layout.fillWidth: true
            visible: root.listError !== ""
            text: root.listError
            color: ui.systemRed
            font.pixelSize: ui.callout
            wrapMode: Text.WordWrap
        }

        // Empty state, in the style of a content-unavailable view.
        ColumnLayout {
            objectName: "motionEmpty"
            visible: !root.loading && !root.listError && root.visibleItems.length === 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 6
            Item { Layout.fillHeight: true }
            Text {
                Layout.alignment: Qt.AlignHCenter
                textFormat: Text.PlainText
                text: ui.iconMotion
                font.family: ui.iconFont
                font.pixelSize: 44
                color: ui.tertiaryLabel
            }
            MacText {
                Layout.alignment: Qt.AlignHCenter
                text: strings.t("motion.emptyTitle")
                font.pixelSize: ui.headline
                font.weight: Font.DemiBold
            }
            MacText {
                Layout.alignment: Qt.AlignHCenter
                Layout.maximumWidth: Math.min(360, root.width - 32)
                text: strings.t("motion.emptyBody")
                color: ui.secondaryLabel
                font.pixelSize: ui.callout
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideNone
            }
            Item { Layout.fillHeight: true }
        }

        GridView {
            id: grid
            objectName: "motionGrid"
            visible: root.visibleItems.length > 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: root.visibleItems
            readonly property int columns: Math.max(2, Math.floor(width / 190))
            cellWidth: Math.floor(width / columns)
            cellHeight: Math.round(cellWidth * 0.62)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            cacheBuffer: cellHeight * 2
            Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }

            delegate: Item {
                id: tile
                required property var modelData
                required property int index
                width: grid.cellWidth
                height: grid.cellHeight
                Item {
                    id: thumb
                    anchors.fill: parent
                    anchors.margins: 3
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        maskEnabled: true
                        maskSource: thumbMask
                        maskThresholdMin: 0.5
                        maskSpreadAtMin: 1.0
                    }
                    Rectangle { anchors.fill: parent; color: "#0e0e10" }
                    Image {
                        anchors.fill: parent
                        source: "file://" + tile.modelData.path
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: false
                        sourceSize.width: 380
                        sourceSize.height: 240
                    }
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 34
                        gradient: Gradient {
                            GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0) }
                            GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.55) }
                        }
                    }
                    Text {
                        objectName: "stillCameraName"
                        visible: root.showCameraNames
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.rightMargin: 8
                        anchors.bottomMargin: 6
                        width: Math.min(implicitWidth, parent.width * 0.45)
                        textFormat: Text.PlainText
                        text: root.cameraLabel(tile.modelData)
                        font.family: ui.font
                        font.pixelSize: ui.caption
                        font.weight: Font.Medium
                        color: Qt.rgba(1, 1, 1, 0.8)
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignRight
                    }
                    Text {
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: 8
                        anchors.bottomMargin: 6
                        width: parent.width * (root.showCameraNames ? 0.5 : 1) - 16
                        textFormat: Text.PlainText
                        text: (tile.modelData.date && tile.modelData.date !== root.today
                            ? root.dayLabel(tile.modelData) + " · " : "") + (tile.modelData.time || tile.modelData.name || "")
                        font.family: ui.font
                        font.pixelSize: ui.caption
                        font.weight: Font.DemiBold
                        font.features: { "tnum": 1 }
                        color: "white"
                        elide: Text.ElideRight
                    }
                    Rectangle {
                        anchors.fill: parent
                        color: "white"
                        opacity: tileMouse.containsMouse ? 0.08 : 0
                        Behavior on opacity { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
                    }
                }
                Item {
                    id: thumbMask
                    anchors.fill: thumb
                    visible: false
                    layer.enabled: true
                    Rectangle { anchors.fill: parent; radius: 8 }
                }
                MouseArea {
                    id: tileMouse
                    anchors.fill: thumb
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.selectedIndex = tile.index
                        root.forceActiveFocus()
                    }
                }
            }
        }
    }

    // Full-size viewer with previous/next navigation (also ←/→ and Esc).
    Rectangle {
        id: preview
        objectName: "motionPreview"
        visible: root.selectedIndex >= 0
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.9)
        radius: 12
        z: 10
        readonly property var item: root.selectedIndex >= 0 && root.selectedIndex < root.visibleItems.length
            ? root.visibleItems[root.selectedIndex] : null
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }

        MouseArea {
            anchors.fill: parent
            onClicked: root.selectedIndex = -1
        }
        Image {
            id: stillImage
            anchors.fill: parent
            anchors.leftMargin: 56
            anchors.rightMargin: 56
            anchors.topMargin: 48
            anchors.bottomMargin: 64
            visible: root.clipState !== "ready"
            source: root.selectedSource
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: false
        }
        MacText {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 16
            width: Math.min(implicitWidth, parent.width - 120)
            text: preview.item ? root.cameraLabel(preview.item) + " · " + root.dayLabel(preview.item) + " · "
                + (preview.item.time || preview.item.name) + "    " + (root.selectedIndex + 1) + " / " + root.visibleItems.length : ""
            color: "white"
            font.pixelSize: ui.callout
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
        }
        // The clip plays where the still was; clicking the video toggles playback.
        Item {
            id: clipView
            objectName: "clipView"
            anchors.fill: stillImage
            visible: root.clipState === "ready"
            MediaPlayer {
                id: clipPlayer
                objectName: "clipPlayer"
                source: root.clipState === "ready" && root.clipPath !== "" ? "file://" + root.clipPath : ""
                videoOutput: clipVideo
                audioOutput: AudioOutput {}
                onSourceChanged: if (source.toString() !== "") play()
            }
            VideoOutput {
                id: clipVideo
                anchors.fill: parent
                fillMode: VideoOutput.PreserveAspectFit
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleClip()
            }
            // A slow camera can leave a clip short; say so on the video itself.
            Rectangle {
                objectName: "clipPartialNote"
                visible: root.clipPartial
                x: Math.max(8, (parent.width - clipVideo.contentRect.width) / 2 + 8)
                y: Math.max(8, (parent.height - clipVideo.contentRect.height) / 2 + 8)
                width: Math.min(partialText.implicitWidth + 20, parent.width - 16)
                height: 24
                radius: height / 2
                color: Qt.rgba(0, 0, 0, 0.6)
                MacText {
                    id: partialText
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, parent.width - 20)
                    text: strings.t("clip.partial")
                    color: ui.systemOrange
                    font.pixelSize: ui.caption
                    font.weight: Font.DemiBold
                }
            }
        }

        // Bottom bar: "Play clip", download progress, an error, or player controls.
        Rectangle {
            id: clipBar
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 14
            // Controls span the viewer (the seek bar takes the free space); other states hug their content.
            width: root.clipState === "ready" ? Math.min(parent.width - 32, 640)
                : Math.min(parent.width - 32, clipRow.implicitWidth + 24)
            height: 40
            radius: height / 2
            visible: root.clipState !== "" || root.clipAvailable
            color: root.clipState === "" ? "transparent" : Qt.rgba(0.12, 0.12, 0.13, 0.82)
            border.width: root.clipState === "" ? 0 : 1
            border.color: Qt.rgba(1, 1, 1, 0.12)
            MouseArea { anchors.fill: parent }  // keep clicks from closing the viewer
            RowLayout {
                id: clipRow
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 10

                GlassPill {
                    objectName: "clipPlayButton"
                    visible: root.clipState === ""
                    glyph: ui.iconPlay
                    text: strings.t("clip.play")
                    onClicked: root.playClip()
                }

                // Fetching
                Text {
                    visible: root.clipState === "fetching"
                    textFormat: Text.PlainText
                    text: ui.iconLoading
                    font.family: ui.iconFont
                    font.pixelSize: 16
                    color: "white"
                    RotationAnimator on rotation {
                        from: 0; to: 360; duration: 1000; loops: Animation.Infinite
                        running: root.clipState === "fetching" && root.visible
                    }
                }
                MacText {
                    objectName: "clipFetchingLabel"
                    visible: root.clipState === "fetching"
                    Layout.fillWidth: true
                    text: strings.t("clip.fetching") + (root.clipProgress > 0 ? "  " + root.megabytes(root.clipProgress) : "")
                    color: "white"
                    font.pixelSize: ui.callout
                    font.features: { "tnum": 1 }
                }
                GlassPill {
                    objectName: "clipCancel"
                    visible: root.clipState === "fetching"
                    text: strings.t("clip.cancel")
                    onClicked: root.closeClip()
                }

                // Error
                MacText {
                    objectName: "clipErrorMessage"
                    visible: root.clipState === "error"
                    Layout.fillWidth: true
                    text: root.clipState === "error" ? root.clipErrorText(root.clipError) : ""
                    color: "white"
                    font.pixelSize: ui.callout
                }
                GlassPill {
                    objectName: "clipRetry"
                    visible: root.clipState === "error"
                    text: strings.t("clip.retry")
                    onClicked: root.playClip()
                }

                // Player
                GlassButton {
                    objectName: "clipToggle"
                    visible: root.clipState === "ready"
                    implicitWidth: 28
                    implicitHeight: 28
                    text: clipPlayer.playbackState === MediaPlayer.PlayingState ? ui.iconPause
                        : clipPlayer.mediaStatus === MediaPlayer.EndOfMedia ? ui.iconReplay : ui.iconPlay
                    tipText: clipPlayer.playbackState === MediaPlayer.PlayingState ? strings.t("clip.pause") : strings.t("clip.resume")
                    onClicked: root.toggleClip()
                }
                MacText {
                    visible: root.clipState === "ready"
                    text: root.clock(clipPlayer.position)
                    color: "white"
                    font.pixelSize: ui.caption
                    font.features: { "tnum": 1 }
                }
                MacSlider {
                    id: clipSeek
                    objectName: "clipSeek"
                    visible: root.clipState === "ready"
                    Layout.fillWidth: true
                    Layout.minimumWidth: 60
                    focusPolicy: Qt.NoFocus
                    from: 0
                    to: Math.max(1, clipPlayer.duration)
                    onMoved: clipPlayer.setPosition(value)
                    Binding on value {
                        when: !clipSeek.pressed
                        value: clipPlayer.position
                    }
                }
                MacText {
                    visible: root.clipState === "ready"
                    text: root.clock(clipPlayer.duration)
                    color: Qt.rgba(1, 1, 1, 0.7)
                    font.pixelSize: ui.caption
                    font.features: { "tnum": 1 }
                }
                GlassButton {
                    objectName: "clipSave"
                    visible: root.clipState === "ready"
                    implicitWidth: 28
                    implicitHeight: 28
                    enabled: root.saveState !== "saving"
                    text: root.saveState === "saved" ? ui.iconCheck : ui.iconDownload
                    tipText: root.saveState === "saved" ? strings.t("clip.saved")
                        : root.saveState === "error" ? strings.t("clip.saveFailed") : strings.t("clip.save")
                    onClicked: root.saveClip()
                }
                GlassButton {
                    objectName: "clipShowStill"
                    visible: root.clipState === "ready"
                    implicitWidth: 28
                    implicitHeight: 28
                    text: ui.iconImage
                    tipText: strings.t("clip.showStill")
                    onClicked: root.closeClip()
                }
            }
        }
        GlassButton {
            objectName: "motionPreviewClose"
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: 10
            text: ui.iconClose
            tipText: strings.t("motion.closePreview")
            onClicked: root.selectedIndex = -1
        }
        GlassButton {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: ui.iconChevronLeft
            tipText: strings.t("motion.newer")
            enabled: root.selectedIndex > 0
            onClicked: root.step(-1)
        }
        GlassButton {
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: ui.iconChevronRight
            tipText: strings.t("motion.older")
            enabled: root.selectedIndex < root.visibleItems.length - 1
            onClicked: root.step(1)
        }
    }

    // Text (optionally with an icon) on a translucent capsule, for the dark viewer.
    component GlassPill: Controls.Button {
        id: glassPill
        property string glyph: ""
        implicitHeight: 30
        leftPadding: 14
        rightPadding: 14
        hoverEnabled: true
        focusPolicy: Qt.TabFocus
        Accessible.name: text
        opacity: enabled ? 1 : 0.4
        contentItem: Row {
            spacing: 7
            Text {
                visible: glassPill.glyph !== ""
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: glassPill.glyph
                font.family: ui.iconFont
                font.pixelSize: 15
                color: "white"
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: glassPill.text
                font.family: ui.font
                font.pixelSize: ui.callout
                font.weight: Font.DemiBold
                color: "white"
            }
        }
        background: Rectangle {
            radius: height / 2
            color: glassPill.down ? Qt.rgba(1, 1, 1, 0.3) : glassPill.hovered ? Qt.rgba(1, 1, 1, 0.24) : Qt.rgba(1, 1, 1, 0.16)
            border.width: glassPill.visualFocus ? 2 : 1
            border.color: glassPill.visualFocus ? ui.alpha(ui.accent, 0.9) : Qt.rgba(1, 1, 1, 0.16)
        }
        PointerArea { visible: glassPill.enabled }
    }

    component GlassButton: Controls.Button {
        id: glassButton
        property string tipText: ""
        implicitWidth: 32
        implicitHeight: 32
        padding: 0
        hoverEnabled: true
        focusPolicy: Qt.TabFocus
        Accessible.name: tipText
        opacity: enabled ? 1 : 0.35
        PanelToolTip {
            visible: glassButton.hovered && glassButton.tipText !== ""
            text: glassButton.tipText
            fontSize: Style.font.caption
        }
        contentItem: Text {
            textFormat: Text.PlainText
            text: glassButton.text
            font.family: ui.iconFont
            font.pixelSize: 17
            color: "white"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: width / 2
            color: glassButton.hovered ? Qt.rgba(1, 1, 1, 0.22) : Qt.rgba(1, 1, 1, 0.12)
            border.width: glassButton.visualFocus ? 2 : 1
            border.color: glassButton.visualFocus ? ui.alpha(ui.accent, 0.9) : Qt.rgba(1, 1, 1, 0.14)
        }
        PointerArea { visible: glassButton.enabled }
    }
}
