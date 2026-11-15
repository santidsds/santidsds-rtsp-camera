import QtQuick
import QtQuick.Controls
import QtQuick.Controls as Controls
import QtQuick.Layouts
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Browse a camera's SD card: pick a day, see the day's recording and motion on
// a timeline, and play from any moment. sdclip.py streams it from the card;
// nothing is saved on this computer.
FocusScope {
    id: root
    Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
    AppleStyle { id: ui }

    property string cameraId: ""
    property string cameraName: ""
    property bool active: false
    property string helper: Qt.resolvedUrl("sdclip.py").toString().replace(/^file:\/\//, "")
    signal closed()

    // The card's index: days, and the shown day's recorded ranges and motion (seconds of day).
    property var days: []
    property string day: ""
    property var ranges: []
    property var motion: []
    property string indexState: ""   // "", "loading", "ready", "error"
    property string indexError: ""
    property string indexFor: ""
    property string pendingDay: ""

    // Playback: one helper session streams from `sessionStart` until `sessionEnd`.
    property string playState: ""    // "", "connecting", "playing", "paused", "ended", "error"
    property string playError: ""
    property string playUrl: ""
    property real sessionStart: -1
    property real sessionEnd: -1
    property real cursor: -1          // the moment picked, or being watched
    property real pendingAt: -1       // waits for the previous helper to stop
    property real startPosition: 0    // player position (ms) when its first frame played
    property real pausedAt: 0
    property real hourOverride: -1
    property real speed: 1
    readonly property var speeds: [1, 1.5, 2, 4]
    readonly property real dayLength: 86400
    readonly property real position: (playState === "playing" || playState === "paused") && sessionStart >= 0
        ? Math.min(dayLength - 1, sessionStart + Math.max(0, player.position - startPosition) / 1000) : cursor
    readonly property real hourStart: hourOverride >= 0 ? hourOverride
        : Math.floor(Math.max(0, position) / 3600) * 3600
    readonly property int motionIndex: {
        var at = position
        for (var i = motion.length - 1; i >= 0; i--)
            if (motion[i][0] - 4 <= at) return i
        return -1
    }

    function seconds(text) {
        var parts = String(text).split(":")
        return parts.length === 3 ? (+parts[0]) * 3600 + (+parts[1]) * 60 + (+parts[2]) : -1
    }
    function clock(value, withSeconds) {
        var total = Math.max(0, Math.floor(value))
        var h = Math.floor(total / 3600), m = Math.floor(total / 60) % 60, s = total % 60
        var text = String(h).padStart(2, "0") + ":" + String(m).padStart(2, "0")
        return withSeconds === false ? text : text + ":" + String(s).padStart(2, "0")
    }
    function dayLabel(value) {
        var today = Qt.formatDate(new Date(), "yyyy-MM-dd")
        if (value === today) return strings.t("motion.today")
        var yesterday = new Date(); yesterday.setDate(yesterday.getDate() - 1)
        if (Qt.formatDate(yesterday, "yyyy-MM-dd") === value) return strings.t("motion.yesterday")
        return new Date(value + "T12:00:00").toLocaleDateString(Qt.locale(Commons.I18n.formatLocale), "ddd d MMM")
    }
    function errorText(code) {
        var keys = {"no-recording": "recordings.error.noRecording", "login": "clip.error.login",
            "unreachable": "clip.error.unreachable", "timeout": "clip.error.timeout",
            "unsupported": "recordings.error.unsupported", "empty": "clip.error.empty"}
        return strings.t(keys[code] || "recordings.error.failed")
    }

    // --- index -------------------------------------------------------------------
    function loadIndex(dayValue) {
        if (!cameraId) return
        if (indexer.running) { pendingDay = dayValue || "-"; return }
        indexState = "loading"
        indexError = ""
        indexer.requested = cameraId
        indexer.command = ["python3", helper, "--index", "--camera", cameraId].concat(dayValue ? ["--date", dayValue] : [])
        indexer.running = true
    }
    function selectDay(value) {
        if (value === day && indexState === "ready") return
        stopPlayback()
        cursor = -1
        hourOverride = -1
        loadIndex(value)
    }
    function applyIndex(result) {
        days = Array.isArray(result.days) ? result.days.filter(function(d) { return /^\d{4}-\d{2}-\d{2}$/.test(d) }) : []
        day = /^\d{4}-\d{2}-\d{2}$/.test(result.date || "") ? result.date : ""
        function pairs(list) {
            return (Array.isArray(list) ? list : []).map(function(p) { return [seconds(p[0]), seconds(p[1])] })
                .filter(function(p) { return p[0] >= 0 && p[1] >= p[0] })
        }
        ranges = pairs(result.ranges)
        motion = pairs(result.motion)
        indexFor = cameraId
        indexState = "ready"
    }

    // --- playback ----------------------------------------------------------------
    function requestPlay(at) {
        if (!day || indexState !== "ready") return
        cursor = Math.max(0, Math.min(dayLength - 1, at))
        hourOverride = -1
        playState = "connecting"
        playError = ""
        debounce.restart()
    }
    function startSession() {
        player.stop()
        playUrl = ""
        if (streamer.running) {
            pendingAt = cursor
            streamer.running = false   // the helper tells the camera to stop, then exits
            return
        }
        pendingAt = -1
        sessionStart = cursor
        sessionEnd = -1
        streamer.gotUrl = false
        streamer.command = ["python3", helper, "--play", "--camera", cameraId, "--at", day + " " + clock(cursor)]
        streamer.running = true
    }
    function stopPlayback() {
        debounce.stop()
        player.stop()
        playUrl = ""
        pendingAt = -1
        if (streamer.running) streamer.running = false
        if (playState !== "error") playState = ""
    }
    function togglePlay() {
        if (playState === "playing") {
            player.pause()
            pausedAt = Date.now()
            playState = "paused"
        } else if (playState === "paused") {
            // A long pause ends the camera's session; start again where we were.
            if (Date.now() - pausedAt > 90000 || !streamer.running) requestPlay(position)
            else { player.play(); playState = "playing" }
        } else if (playState === "ended" || playState === "error" || playState === "") {
            requestPlay(cursor >= 0 ? cursor : (motion.length ? motion[motion.length - 1][0] - 3 : 0))
        }
    }
    function seekBy(delta) {
        if (cursor < 0 && playState === "") return
        requestPlay(position + delta)
    }
    function jumpMotion(direction) {
        if (motion.length === 0) return
        var at = position, target = -1
        if (direction > 0) {
            for (var i = 0; i < motion.length; i++) if (motion[i][0] - 3 > at + 1) { target = motion[i][0]; break }
        } else {
            for (var j = motion.length - 1; j >= 0; j--) if (motion[j][0] - 3 < at - 2) { target = motion[j][0]; break }
        }
        if (target >= 0) requestPlay(target - 3)
    }
    function handleStreamLine(line) {
        var message
        try { message = JSON.parse(line) } catch (error) { return }
        if (!message || typeof message !== "object" || pendingAt >= 0) return
        if (typeof message.url === "string" && /^http:\/\/127\.0\.0\.1:\d+\//.test(message.url)) {
            streamer.gotUrl = true
            var start = String(message.start || "").split(" ")
            if (start[0] === day) sessionStart = seconds(start[1])
            var end = String(message.end || "").split(" ")
            sessionEnd = end[0] === day ? seconds(end[1]) : dayLength - 1
            cursor = sessionStart
            playUrl = message.url
            return
        }
        if (typeof message.first === "string") {
            var first = message.first.split(" ")
            if (first[0] === day) sessionStart = seconds(first[1])
            return
        }
        if (message.ok === false && (playState === "connecting" || playState === "playing")) {
            playError = String(message.error || "failed")
            playState = "error"
            player.stop()
        }
    }

    onActiveChanged: {
        if (!active) { stopPlayback(); playState = ""; return }
        forceActiveFocus()
        if (cameraId && (indexFor !== cameraId || indexState === "error")) loadIndex("")
    }
    onCameraIdChanged: {
        stopPlayback()
        playState = ""
        days = []; ranges = []; motion = []; day = ""; cursor = -1; indexFor = ""; indexState = ""
        if (active && cameraId) loadIndex("")
    }

    Keys.onSpacePressed: function(event) { event.accepted = true; togglePlay() }
    Keys.onLeftPressed: function(event) { event.accepted = true; seekBy(-10) }
    Keys.onRightPressed: function(event) { event.accepted = true; seekBy(10) }
    Keys.onUpPressed: function(event) { event.accepted = true; jumpMotion(-1) }
    Keys.onDownPressed: function(event) { event.accepted = true; jumpMotion(1) }

    Timer { id: debounce; interval: 250; onTriggered: root.startSession() }

    Process {
        id: indexer
        property string requested: ""
        stdout: StdioCollector { id: indexOut }
        onExited: function(code) {
            if (requested !== root.cameraId) { root.indexState = ""; if (root.active) root.loadIndex(""); return }
            var lines = indexOut.text.trim().split("\n"), result = null
            try { result = JSON.parse(lines[lines.length - 1]) } catch (error) {}
            if (result && result.ok === true) root.applyIndex(result)
            else {
                root.indexError = result && result.error ? String(result.error) : "failed"
                root.indexState = "error"
            }
            if (root.pendingDay !== "") {
                var next = root.pendingDay === "-" ? "" : root.pendingDay
                root.pendingDay = ""
                root.loadIndex(next)
            }
        }
    }
    Process {
        id: streamer
        property bool gotUrl: false
        stdout: SplitParser { onRead: function(line) { root.handleStreamLine(line) } }
        onExited: function(code) {
            if (root.pendingAt >= 0) {
                root.cursor = root.pendingAt
                root.startSession()
                return
            }
            if (root.playState === "connecting" && !gotUrl) {
                root.playError = "failed"
                root.playState = "error"
            }
        }
    }
    MediaPlayer {
        id: player
        objectName: "recordingPlayer"
        source: root.playUrl
        videoOutput: video
        audioOutput: AudioOutput { id: speaker }
        playbackRate: root.speed  // the helper follows: a faster player pulls the camera faster
        onSourceChanged: if (source.toString() !== "") play()
        onPlaybackStateChanged: {
            if (playbackState === MediaPlayer.PlayingState && root.playState === "connecting") {
                root.startPosition = position
                root.playState = "playing"
            }
        }
        onMediaStatusChanged: {
            if (mediaStatus !== MediaPlayer.EndOfMedia || root.playState !== "playing") return
            // A session covers up to 30 minutes; carry on with the next one until the day ends.
            if (root.sessionEnd >= 0 && root.sessionEnd < root.dayLength - 2) root.requestPlay(root.sessionEnd)
            else { root.cursor = root.position; root.playState = "ended" }
        }
        onErrorOccurred: {
            if (root.playState !== "connecting" && root.playState !== "playing") return
            root.cursor = root.position
            root.playError = "failed"
            root.playState = "error"
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 2
            spacing: 10
            ColumnLayout {
                spacing: 1
                MacText {
                    text: strings.t("recordings.title")
                    font.pixelSize: ui.largeTitle
                    font.weight: Font.Bold
                }
                MacText {
                    objectName: "recordingsSubtitle"
                    Layout.fillWidth: true
                    text: root.indexState === "loading" ? strings.t("recordings.loading")
                        : root.indexState === "error" ? root.errorText(root.indexError)
                        : root.cameraName.slice(0, 64) + " · " + strings.tn("recordings.days", root.days.length)
                            .arg(Commons.I18n.formatNumber(root.days.length))
                    color: root.indexState === "error" ? ui.systemRed : ui.secondaryLabel
                    font.pixelSize: ui.callout
                }
            }
            Item { Layout.fillWidth: true }
            MacToolbarButton {
                objectName: "recordingsRefresh"
                glyph: ui.iconRefresh
                tipText: strings.t("motion.refresh")
                enabled: root.indexState !== "loading"
                onClicked: root.loadIndex(root.day)
            }
        }

        ListView {
            id: dayStrip
            objectName: "recordingDays"
            Layout.fillWidth: true
            implicitHeight: ui.controlHeight
            visible: root.days.length > 0
            orientation: ListView.Horizontal
            spacing: 6
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.days
            delegate: MacButton {
                required property string modelData
                text: root.dayLabel(modelData)
                role: modelData === root.day ? "default" : "normal"
                onClicked: root.selectDay(modelData)
            }
        }

        // Video
        Rectangle {
            id: stage
            objectName: "recordingStage"
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 120
            radius: ui.videoRadius
            color: "#0e0e10"
            clip: true
            VideoOutput {
                id: video
                anchors.fill: parent
                fillMode: VideoOutput.PreserveAspectFit
                visible: root.playState === "playing" || root.playState === "paused"
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: root.playState === "playing" || root.playState === "paused" ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: { root.forceActiveFocus(); if (root.playState === "playing" || root.playState === "paused") root.togglePlay() }
            }
            MacText {
                objectName: "recordingHint"
                anchors.centerIn: parent
                width: Math.min(implicitWidth, parent.width - 32)
                visible: root.indexState === "ready" && root.playState === ""
                text: root.ranges.length ? strings.t("recordings.hint") : strings.t("recordings.empty")
                color: Qt.rgba(1, 1, 1, 0.62)
                font.pixelSize: ui.callout
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                elide: Text.ElideNone
            }
            // When: day and time of what's on screen.
            Rectangle {
                objectName: "recordingClock"
                visible: root.cursor >= 0
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: 10
                width: clockText.implicitWidth + 20
                height: 26
                radius: height / 2
                color: Qt.rgba(0, 0, 0, 0.55)
                MacText {
                    id: clockText
                    anchors.centerIn: parent
                    text: root.dayLabel(root.day) + " · " + root.clock(root.position)
                    color: "white"
                    font.pixelSize: ui.callout
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                }
            }
            Rectangle {
                objectName: "recordingStatus"
                visible: root.playState === "connecting" || root.playState === "error" || root.playState === "ended"
                anchors.centerIn: parent
                width: Math.min(parent.width - 32, statusRow.implicitWidth + 28)
                height: 38
                radius: height / 2
                color: Qt.rgba(0.12, 0.12, 0.13, 0.86)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.12)
                RowLayout {
                    id: statusRow
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    spacing: 9
                    Text {
                        visible: root.playState === "connecting"
                        textFormat: Text.PlainText
                        text: ui.iconLoading
                        font.family: ui.iconFont
                        font.pixelSize: 16
                        color: "white"
                        RotationAnimator on rotation {
                            from: 0; to: 360; duration: 1000; loops: Animation.Infinite
                            running: root.playState === "connecting" && root.visible
                        }
                    }
                    MacText {
                        objectName: "recordingStatusText"
                        Layout.fillWidth: true
                        text: root.playState === "connecting" ? strings.t("recordings.connecting")
                            : root.playState === "ended" ? strings.t("recordings.ended")
                            : root.errorText(root.playError)
                        color: "white"
                        font.pixelSize: ui.callout
                    }
                }
            }
        }

        // Transport, with the playback speed on the right.
        RowLayout {
            Layout.fillWidth: true
            spacing: 4
            Item { Layout.preferredWidth: speedControl.implicitWidth }  // keeps the buttons centred
            Item { Layout.fillWidth: true }
            MacToolbarButton {
                objectName: "recordingPrevMotion"
                glyph: ui.iconSkipPrevious
                tipText: strings.t("recordings.prevMotion")
                enabled: root.motion.length > 0 && root.indexState === "ready"
                onClicked: { root.forceActiveFocus(); root.jumpMotion(-1) }
            }
            MacToolbarButton {
                objectName: "recordingBack"
                glyph: ui.iconBack
                tipText: strings.t("recordings.back10")
                enabled: root.cursor >= 0
                onClicked: { root.forceActiveFocus(); root.seekBy(-10) }
            }
            MacToolbarButton {
                objectName: "recordingPlay"
                glyph: root.playState === "playing" || root.playState === "connecting" ? ui.iconPause : ui.iconPlay
                iconSize: 20
                tipText: root.playState === "playing" ? strings.t("clip.pause") : strings.t("clip.resume")
                enabled: root.indexState === "ready" && root.ranges.length > 0
                onClicked: { root.forceActiveFocus(); root.togglePlay() }
            }
            MacToolbarButton {
                objectName: "recordingForward"
                glyph: ui.iconForward
                tipText: strings.t("recordings.forward10")
                enabled: root.cursor >= 0
                onClicked: { root.forceActiveFocus(); root.seekBy(10) }
            }
            MacToolbarButton {
                objectName: "recordingNextMotion"
                glyph: ui.iconSkipNext
                tipText: strings.t("recordings.nextMotion")
                enabled: root.motion.length > 0 && root.indexState === "ready"
                onClicked: { root.forceActiveFocus(); root.jumpMotion(1) }
            }
            Item { Layout.fillWidth: true }
            MacSegmented {
                id: speedControl
                objectName: "recordingSpeed"
                model: root.speeds.map(function(rate) { return Commons.I18n.formatNumber(rate) + "×" })
                tips: root.speeds.map(function(rate) { return strings.t("recordings.speed").arg(Commons.I18n.formatNumber(rate)) })
                segmentNames: ["speed1", "speed15", "speed2", "speed4"]
                autoSelect: false
                currentIndex: root.speeds.indexOf(root.speed)
                onActivated: function(index) { root.speed = root.speeds[index]; root.forceActiveFocus() }
            }
        }

        // The whole day, then a close-up of one hour.
        Timeline {
            id: dayLine
            objectName: "dayTimeline"
            Layout.fillWidth: true
            from: 0
            to: root.dayLength
            tickEvery: 3 * 3600
            tickLabel: function(value) { return root.clock(value, false).slice(0, 2) }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 4
            MacToolbarButton {
                objectName: "recordingPrevHour"
                glyph: ui.iconChevronLeft
                tipText: strings.t("recordings.prevHour")
                enabled: root.hourStart > 0
                onClicked: root.hourOverride = Math.max(0, root.hourStart - 3600)
            }
            Timeline {
                id: hourLine
                objectName: "hourTimeline"
                Layout.fillWidth: true
                from: root.hourStart
                to: root.hourStart + 3600
                tickEvery: 600
                tickLabel: function(value) { return root.clock(value, false) }
            }
            MacToolbarButton {
                objectName: "recordingNextHour"
                glyph: ui.iconChevronRight
                tipText: strings.t("recordings.nextHour")
                enabled: root.hourStart < root.dayLength - 3600
                onClicked: root.hourOverride = Math.min(root.dayLength - 3600, root.hourStart + 3600)
            }
        }

        // Motion events: jump straight to one.
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: root.indexState === "ready"
            MacText {
                objectName: "motionEventCount"
                text: root.motion.length ? strings.tn("recordings.motionCount", root.motion.length)
                    .arg(Commons.I18n.formatNumber(root.motion.length)) : strings.t("recordings.noMotion")
                color: ui.secondaryLabel
                font.pixelSize: ui.caption
                font.weight: Font.Medium
            }
            ListView {
                id: motionList
                objectName: "motionEvents"
                Layout.fillWidth: true
                implicitHeight: 24
                orientation: ListView.Horizontal
                spacing: 5
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: root.motion
                currentIndex: root.motionIndex
                onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
                delegate: Controls.Button {
                    id: chip
                    required property var modelData
                    required property int index
                    readonly property bool current: index === root.motionIndex
                    implicitHeight: 24
                    leftPadding: 9
                    rightPadding: 9
                    hoverEnabled: true
                    focusPolicy: Qt.NoFocus
                    Accessible.name: chipText.text
                    contentItem: Text {
                        id: chipText
                        textFormat: Text.PlainText
                        text: root.clock(chip.modelData[0], false)
                        font.family: ui.font
                        font.pixelSize: ui.caption
                        font.weight: Font.DemiBold
                        font.features: { "tnum": 1 }
                        color: chip.current ? "#1c1c1e" : ui.label
                        verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        radius: height / 2
                        color: chip.current ? ui.systemOrange : chip.hovered ? ui.fillHover : ui.fill
                    }
                    onClicked: { root.forceActiveFocus(); root.requestPlay(chip.modelData[0] - 3) }
                    PointerArea {}
                }
            }
        }
    }

    // A time track: recorded time as a soft bar, motion in orange, ticks, a playhead.
    component Timeline: Item {
        id: line
        property real from: 0
        property real to: 3600
        property real tickEvery: 600
        property var tickLabel: function(value) { return "" }
        readonly property real span: Math.max(1, to - from)
        readonly property real hoverAt: hover.hovered ? from + Math.max(0, Math.min(1, hover.point.position.x / width)) * span : -1
        function xOf(value) { return (value - from) / span * width }
        implicitHeight: 36

        Rectangle {
            id: track
            width: parent.width
            height: 16
            radius: 4
            color: ui.fill
            clip: true
            Repeater {
                model: root.ranges
                Rectangle {
                    required property var modelData
                    visible: modelData[1] >= line.from && modelData[0] <= line.to
                    x: Math.max(0, line.xOf(modelData[0]))
                    width: Math.max(1, Math.min(line.width, line.xOf(modelData[1])) - x)
                    height: parent.height
                    color: ui.alpha(ui.label, 0.22)
                }
            }
            Repeater {
                model: root.motion
                Rectangle {
                    required property var modelData
                    visible: modelData[1] >= line.from && modelData[0] <= line.to
                    x: Math.max(0, line.xOf(modelData[0]))
                    width: Math.max(2, Math.min(line.width, line.xOf(modelData[1])) - x)
                    height: parent.height
                    color: ui.systemOrange
                }
            }
            Rectangle {  // playhead
                visible: root.cursor >= 0 && root.position >= line.from && root.position <= line.to
                x: line.xOf(root.position) - 1
                width: 2
                height: parent.height + 4
                y: -2
                color: ui.accent
            }
            Rectangle {  // hover marker
                visible: line.hoverAt >= 0
                x: line.xOf(line.hoverAt)
                width: 1
                height: parent.height
                color: ui.alpha(ui.label, 0.7)
            }
        }
        Repeater {
            model: Math.floor(line.span / line.tickEvery) + 1
            Text {
                required property int index
                readonly property real value: line.from + index * line.tickEvery
                x: Math.max(0, Math.min(line.width - width, line.xOf(value) - width / 2))
                y: track.height + 3
                textFormat: Text.PlainText
                text: line.tickLabel(value)
                font.family: ui.font
                font.pixelSize: 10
                font.features: { "tnum": 1 }
                color: ui.tertiaryLabel
            }
        }
        Rectangle {  // hover time
            visible: line.hoverAt >= 0
            x: Math.max(0, Math.min(line.width - width, line.xOf(line.hoverAt) - width / 2))
            y: track.height + 1
            width: hoverText.implicitWidth + 10
            height: 16
            radius: 4
            color: ui.menuBackground
            border.width: 1
            border.color: ui.separator
            MacText {
                id: hoverText
                anchors.centerIn: parent
                text: root.clock(line.hoverAt)
                font.pixelSize: 10
                font.features: { "tnum": 1 }
            }
        }
        HoverHandler { id: hover }
        MouseArea {
            anchors.fill: track
            cursorShape: Qt.PointingHandCursor
            onClicked: function(mouse) {
                root.forceActiveFocus()
                root.requestPlay(line.from + Math.max(0, Math.min(1, mouse.x / width)) * line.span)
            }
        }
    }
}
