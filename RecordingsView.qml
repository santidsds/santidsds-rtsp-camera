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
// nothing is saved on this computer. In full screen ("immersive") the video
// fills the card and the controls float over it, hiding when idle.
FocusScope {
    id: root
    Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
    AppleStyle { id: ui }

    property string cameraId: ""
    property string cameraName: ""
    property bool active: false
    property bool immersive: false
    property string helper: Qt.resolvedUrl("sdclip.py").toString().replace(/^file:\/\//, "")
    property string stillsHelper: Qt.resolvedUrl("motiond.py").toString().replace(/^file:\/\//, "")
    signal closed()

    // The card's index: days, and the shown day's recorded ranges and motion (seconds of day).
    property var days: []
    property string day: ""
    property var ranges: []
    property var motion: []
    property var density: []          // motion starts per 10 minutes, for the 24 h bar
    property int densityMax: 1
    property var chipLabels: []       // HH:MM, or HH:MM:SS where two events share a minute
    property var stills: []           // this camera's motion stills for the day: {sec, path}
    property string indexState: ""    // "", "loading", "ready", "error"
    property string indexError: ""
    property string indexFor: ""
    property string pendingDay: ""
    property var pendingOpen: null    // {camera, day, at}: open a moment once its day is loaded

    // Playback: one helper session streams from `sessionStart` until `sessionEnd`.
    property string playState: ""     // "", "connecting", "playing", "paused", "ended", "error"
    property string playError: ""
    property string playUrl: ""
    property real sessionStart: -1
    property real sessionEnd: -1
    property real cursor: -1          // the moment picked, or being watched
    property real pendingAt: -1       // waits for the previous helper to stop
    property real startPosition: 0    // player position (ms) when its first frame played
    property real pausedAt: 0
    property real hourOverride: -1
    property real lastStart: 0        // when a helper last started (each start is a camera login)
    property bool chaining: false     // the current session continues the previous one
    property real indexLoadedAt: 0
    property real speed: 1
    readonly property var speeds: [1, 1.5, 2, 4]
    property url lastFrame: ""        // the frame on screen when a jump started, shown dimmed
    property bool controlsShown: true
    readonly property real dayLength: 86400
    readonly property bool showingVideo: playState === "playing" || playState === "paused"
    readonly property real position: showingVideo && sessionStart >= 0
        ? Math.min(dayLength - 1, sessionStart + Math.max(0, player.position - startPosition) / 1000) : cursor
    readonly property real hourStart: hourOverride >= 0 ? hourOverride
        : Math.floor(Math.max(0, position) / 3600) * 3600
    readonly property int motionIndex: {
        var at = position
        for (var i = motion.length - 1; i >= 0; i--)
            if (motion[i][0] - 4 <= at) return i
        return -1
    }
    readonly property string posterPath: showingVideo ? "" : stillNear(cursor, 25)
    readonly property bool canPlay: indexState === "ready" && ranges.length > 0

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
    function today() { return Qt.formatDate(new Date(), "yyyy-MM-dd") }
    function dayLabel(value) {
        if (value === today()) return strings.t("motion.today")
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
    function retryable(code) { return code !== "login" && code !== "unsupported" }
    function stillNear(at, tolerance) {
        if (at < 0) return ""
        var best = "", gap = tolerance + 1
        for (var i = 0; i < stills.length; i++) {
            var d = Math.abs(stills[i].sec - at)
            if (d < gap) { gap = d; best = stills[i].path }
        }
        return best
    }

    // --- index -------------------------------------------------------------------
    function loadIndex(dayValue) {
        if (!cameraId) return
        if (!dayValue && pendingOpen && pendingOpen.camera === cameraId) dayValue = pendingOpen.day
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
        playState = ""
        cursor = -1
        hourOverride = -1
        loadIndex(value)
    }
    // Open a moment (from a motion still, or Live's last-motion chip).
    function openAt(camera, dayValue, at) {
        pendingOpen = {camera: camera, day: dayValue, at: at}
        if (camera !== cameraId) return  // onCameraIdChanged picks it up
        if (indexState === "ready" && day === dayValue) applyPendingOpen()
        else { stopPlayback(); playState = ""; loadIndex(dayValue) }
    }
    function applyPendingOpen() {
        var open = pendingOpen
        if (!open || open.camera !== cameraId || open.day !== day) return false
        pendingOpen = null
        requestPlay(open.at)
        return true
    }
    function applyIndex(result) {
        days = Array.isArray(result.days) ? result.days.filter(function(d) { return /^\d{4}-\d{2}-\d{2}$/.test(d) }) : []
        var newDay = /^\d{4}-\d{2}-\d{2}$/.test(result.date || "") ? result.date : ""
        function pairs(list) {
            return (Array.isArray(list) ? list : []).map(function(p) { return [seconds(p[0]), seconds(p[1])] })
                .filter(function(p) { return p[0] >= 0 && p[1] >= p[0] })
        }
        var dayChanged = newDay !== day
        day = newDay
        ranges = pairs(result.ranges)
        motion = pairs(result.motion)
        var bins = [], top = 1
        for (var b = 0; b < 144; b++) bins.push(0)
        for (var i = 0; i < motion.length; i++) {
            var bin = Math.min(143, Math.floor(motion[i][0] / 600))
            bins[bin]++
            top = Math.max(top, bins[bin])
        }
        density = bins
        densityMax = top
        var labels = []
        for (var j = 0; j < motion.length; j++) {
            var minute = clock(motion[j][0], false)
            var shared = (j > 0 && clock(motion[j - 1][0], false) === minute)
                || (j + 1 < motion.length && clock(motion[j + 1][0], false) === minute)
            labels.push(shared ? clock(motion[j][0]) : minute)
        }
        chipLabels = labels
        indexFor = cameraId
        indexLoadedAt = Date.now()
        indexState = "ready"
        loadStills()
        if (applyPendingOpen()) return
        // Open on the latest event (or the latest recording) instead of a blank day.
        if (dayChanged || cursor < 0) {
            hourOverride = -1
            cursor = motion.length ? Math.max(0, motion[motion.length - 1][0] - 3)
                : ranges.length ? Math.max(0, ranges[ranges.length - 1][1] - 60) : -1
        }
    }
    function loadStills() {
        if (stillLister.running) return
        stillLister.wanted = cameraId + " " + day
        stillLister.running = true
    }

    // --- playback ----------------------------------------------------------------
    function requestPlay(at, continuing) {
        if (!day || indexState !== "ready") return
        cursor = Math.max(0, Math.min(dayLength - 1, at))
        hourOverride = -1
        chaining = continuing === true
        playState = "connecting"
        playError = ""
        showControls()
        // Every start is a login on the camera: keep them at least 1.5 s apart.
        debounce.interval = Math.max(250, 1500 - (Date.now() - lastStart))
        debounce.restart()
    }
    function startSession() {
        // Keep what was on screen, dimmed, until the new moment arrives.
        if (player.playbackState !== MediaPlayer.StoppedState && video.visible)
            video.grabToImage(function(result) { root.lastFrame = result.url })
        player.stop()
        playUrl = ""
        playState = "connecting"
        playError = ""
        if (streamer.running) {
            pendingAt = cursor
            streamer.running = false   // the helper tells the camera to stop, then exits
            return
        }
        pendingAt = -1
        sessionStart = cursor
        sessionEnd = -1
        lastStart = Date.now()
        streamer.gotUrl = false
        streamer.command = ["python3", helper, "--play", "--camera", cameraId, "--at", day + " " + clock(cursor)]
        streamer.running = true
    }
    function stopPlayback() {
        debounce.stop()
        player.stop()
        playUrl = ""
        pendingAt = -1
        lastFrame = ""
        if (streamer.running) streamer.running = false
        if (playState !== "error") playState = ""
    }
    function togglePlay() {
        if (playState === "playing") {
            player.pause()
            pausedAt = Date.now()
            playState = "paused"
        } else if (playState === "connecting") {
            stopPlayback()  // changed your mind while it loads
        } else if (playState === "paused") {
            // A long pause ends the camera's session; start again where we were.
            if (Date.now() - pausedAt > 90000 || !streamer.running) requestPlay(position)
            else { player.play(); playState = "playing" }
        } else if (canPlay) {
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
    function stepHour(direction) {
        hourOverride = Math.max(0, Math.min(dayLength - 3600, hourStart + direction * 3600))
        showControls()
    }
    function handleStreamLine(line) {
        var message
        try { message = JSON.parse(line) } catch (error) { return }
        // Lines from a session being replaced (or about to be) don't count.
        if (!message || typeof message !== "object" || pendingAt >= 0 || debounce.running) return
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
        if (message.ok === false && message.error !== "cancelled"
                && (playState === "connecting" || playState === "playing")) {
            // Running into the end of what's recorded while continuing is just the end.
            if (chaining && message.error === "no-recording") {
                playState = "ended"
            } else {
                playError = String(message.error || "failed")
                playState = "error"
            }
            player.stop()
        }
    }
    function showControls() {
        controlsShown = true
        if (immersive) idle.restart()
    }

    onActiveChanged: {
        if (!active) { stopPlayback(); playState = ""; return }
        forceActiveFocus()
        if (pendingOpen && pendingOpen.camera !== cameraId) return  // the camera switch loads it
        if (cameraId && (indexFor !== cameraId || indexState === "error")) loadIndex("")
        else if (day === today() && Date.now() - indexLoadedAt > 60000)
            loadIndex(day)  // today keeps recording: refresh on the way back in
    }
    onCameraIdChanged: {
        stopPlayback()
        playState = ""
        days = []; ranges = []; motion = []; density = []; chipLabels = []; stills = []
        day = ""; cursor = -1; indexFor = ""; indexState = ""
        if (active && cameraId) loadIndex("")
    }
    onImmersiveChanged: { controlsShown = true; if (immersive) idle.restart(); else idle.stop() }

    Keys.onPressed: function(event) {
        var key = event.key
        if (key === Qt.Key_Space) togglePlay()
        else if (key === Qt.Key_Left) seekBy(-10)
        else if (key === Qt.Key_Right) seekBy(10)
        else if (key === Qt.Key_Up) jumpMotion(-1)
        else if (key === Qt.Key_Down) jumpMotion(1)
        else if (key === Qt.Key_Comma) stepHour(-1)
        else if (key === Qt.Key_Period) stepHour(1)
        else if (key >= Qt.Key_1 && key <= Qt.Key_4 && !(event.modifiers & Qt.ControlModifier)) speed = speeds[key - Qt.Key_1]
        else return
        event.accepted = true
        showControls()
    }

    Timer { id: debounce; interval: 250; onTriggered: root.startSession() }
    Timer {
        id: idle
        interval: 2500
        onTriggered: if (root.immersive && root.playState === "playing" && !controlsHover.hovered) root.controlsShown = false
    }

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
    // The motion stills saved on this computer (last 24 h): covers and chip previews.
    Process {
        id: stillLister
        property string wanted: ""
        command: ["python3", root.stillsHelper, "--list"]
        stdout: StdioCollector { id: stillsOut }
        onExited: function(code) {
            var list = []
            try { list = JSON.parse(stillsOut.text || "[]") } catch (error) {}
            var parts = wanted.split(" "), found = []
            if (Array.isArray(list))
                for (var i = 0; i < list.length; i++) {
                    var item = list[i]
                    if (item && item.cameraId === parts[0] && item.date === parts[1] && typeof item.path === "string") {
                        var sec = root.seconds(item.time)
                        if (sec >= 0) found.push({sec: sec, path: item.path})
                    }
                }
            if (wanted === root.cameraId + " " + root.day) root.stills = found
            else if (root.indexState === "ready") root.loadStills()
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
                root.lastFrame = ""
                root.showControls()
            }
        }
        onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.EndOfMedia && root.playState === "connecting") {
                root.playError = "failed"  // the stream ended before anything played
                root.playState = "error"
                return
            }
            if (mediaStatus !== MediaPlayer.EndOfMedia || root.playState !== "playing") return
            var reached = root.position
            root.cursor = reached
            if (root.sessionEnd >= 0 && reached < root.sessionEnd - 5) {
                // Ended early (the camera stopped sending): carry on from here, once.
                if (root.chaining && reached - root.sessionStart < 10) { root.playError = "timeout"; root.playState = "error" }
                else root.requestPlay(reached, true)
            } else if (root.sessionEnd >= 0 && root.sessionEnd < root.dayLength - 2) {
                // A session covers one stretch of recording (up to 30 min); go on to the next.
                root.requestPlay(root.sessionEnd + 1, true)
            } else {
                root.playState = "ended"
            }
        }
        onErrorOccurred: {
            if (root.playState !== "connecting" && root.playState !== "playing") return
            root.cursor = root.position
            root.playError = "failed"
            root.playState = "error"
        }
    }

    // --- layout ------------------------------------------------------------------
    // Card: day strip on top, video, controls below. Immersive: video fills, controls float.
    RowLayout {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: visible ? ui.controlHeight : 0
        visible: !root.immersive
        spacing: 6
        DayStrip {
            Layout.fillWidth: true
            Layout.fillHeight: true
        }
        MacToolbarButton {
            objectName: "recordingsRefresh"
            glyph: ui.iconRefresh
            tipText: root.indexState === "ready"
                ? root.cameraName.slice(0, 64) + " · " + strings.tn("recordings.days", root.days.length)
                    .arg(Commons.I18n.formatNumber(root.days.length)) + "\n" + strings.t("motion.refresh")
                : strings.t("motion.refresh")
            enabled: root.indexState !== "loading"
            onClicked: root.loadIndex(root.day)
        }
    }

    Rectangle {
        id: stage
        objectName: "recordingStage"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: root.immersive ? parent.top : header.bottom
        anchors.topMargin: root.immersive ? 0 : 8
        anchors.bottom: root.immersive ? parent.bottom : controls.top
        anchors.bottomMargin: root.immersive ? 0 : 8
        radius: ui.videoRadius
        color: "#0e0e10"
        clip: true

        Image {
            objectName: "recordingPoster"
            anchors.fill: parent
            source: root.posterPath ? "file://" + root.posterPath : ""
            visible: root.posterPath !== "" && !root.showingVideo && root.lastFrame.toString() === ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: false
            opacity: 0.55
        }
        Image {
            anchors.fill: parent
            source: root.lastFrame
            visible: root.playState === "connecting" && root.lastFrame.toString() !== ""
            fillMode: Image.PreserveAspectFit
            opacity: 0.4
        }
        VideoOutput {
            id: video
            anchors.fill: parent
            fillMode: VideoOutput.PreserveAspectFit
            visible: root.showingVideo
        }
        MouseArea {
            anchors.fill: parent
            hoverEnabled: root.immersive
            cursorShape: root.immersive && !root.controlsShown ? Qt.BlankCursor
                : root.showingVideo ? Qt.PointingHandCursor : Qt.ArrowCursor
            onPositionChanged: root.showControls()
            onClicked: { root.forceActiveFocus(); root.showControls(); if (root.showingVideo) root.togglePlay() }
            onDoubleClicked: root.togglePlay()
        }

        // The moment on screen.
        Rectangle {
            objectName: "recordingClock"
            visible: root.cursor >= 0 && (!root.immersive || root.controlsShown)
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: 12
            width: clockText.implicitWidth + 22
            height: 28
            radius: height / 2
            color: Qt.rgba(0, 0, 0, 0.55)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.12)
            MacText {
                id: clockText
                anchors.centerIn: parent
                text: (root.immersive ? root.cameraName.slice(0, 40) + " · " : "")
                    + root.dayLabel(root.day) + " · " + root.clock(root.position)
                color: "white"
                font.pixelSize: ui.callout
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
            }
        }

        // Big play button over the cover (nothing plays until asked: each start is a camera login).
        Controls.Button {
            id: bigPlay
            objectName: "recordingBigPlay"
            anchors.centerIn: parent
            visible: root.canPlay && root.cursor >= 0
                && (root.playState === "" || root.playState === "ended" || root.playState === "paused")
            width: 64
            height: 64
            hoverEnabled: true
            focusPolicy: Qt.NoFocus
            Accessible.name: strings.t("clip.resume")
            contentItem: Text {
                textFormat: Text.PlainText
                text: root.playState === "ended" ? ui.iconReplay : ui.iconPlay
                font.family: ui.iconFont
                font.pixelSize: 34
                color: "white"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                leftPadding: root.playState === "ended" ? 0 : 4
            }
            background: Rectangle {
                radius: width / 2
                color: bigPlay.down ? Qt.rgba(0, 0, 0, 0.75) : bigPlay.hovered ? Qt.rgba(0, 0, 0, 0.62) : Qt.rgba(0, 0, 0, 0.48)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.22)
            }
            onClicked: { root.forceActiveFocus(); root.togglePlay() }
            PointerArea {}
        }

        // Loading, errors, end of the day.
        Rectangle {
            id: statusPill
            objectName: "recordingStatus"
            readonly property string mode: root.indexState === "loading" ? "index"
                : root.indexState === "error" ? "indexError"
                : root.playState === "connecting" ? "connecting"
                : root.playState === "error" ? "error"
                : root.playState === "ended" ? "ended"
                : root.indexState === "ready" && root.ranges.length === 0 ? "empty" : ""
            visible: mode !== ""
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: bigPlay.visible ? 62 : 0
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
                anchors.rightMargin: 8
                spacing: 9
                Text {
                    visible: statusPill.mode === "index" || statusPill.mode === "connecting"
                    textFormat: Text.PlainText
                    text: ui.iconLoading
                    font.family: ui.iconFont
                    font.pixelSize: 16
                    color: "white"
                    RotationAnimator on rotation {
                        from: 0; to: 360; duration: 1000; loops: Animation.Infinite
                        running: statusPill.visible && root.visible
                    }
                }
                MacText {
                    objectName: "recordingStatusText"
                    Layout.fillWidth: true
                    text: statusPill.mode === "index" ? strings.t("recordings.loading")
                        : statusPill.mode === "indexError" ? root.errorText(root.indexError)
                        : statusPill.mode === "connecting" ? strings.t("recordings.connectingAt").arg(root.clock(root.cursor))
                        : statusPill.mode === "ended" ? strings.t("recordings.ended")
                        : statusPill.mode === "empty" ? strings.t("recordings.empty")
                        : root.errorText(root.playError)
                    color: "white"
                    font.pixelSize: ui.callout
                    font.features: { "tnum": 1 }
                }
                GlassPill {
                    objectName: "recordingRetry"
                    visible: (statusPill.mode === "indexError" && root.retryable(root.indexError))
                        || (statusPill.mode === "error" && root.retryable(root.playError))
                    text: strings.t("clip.retry")
                    onClicked: statusPill.mode === "indexError" ? root.loadIndex(root.day) : root.requestPlay(root.cursor)
                }
            }
        }
    }

    // Controls: transport + speed in one capsule, the 24 h bar, the hour close-up, motion chips.
    Rectangle {
        id: controls
        objectName: "recordingControls"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: root.immersive ? 16 : 0
        height: controlsColumn.implicitHeight + (root.immersive ? 24 : 0)
        radius: 14
        color: root.immersive ? Qt.rgba(0.08, 0.08, 0.09, 0.78) : "transparent"
        border.width: root.immersive ? 1 : 0
        border.color: Qt.rgba(1, 1, 1, 0.10)
        opacity: !root.immersive || root.controlsShown ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic } }
        HoverHandler { id: controlsHover; onHoveredChanged: if (hovered) root.showControls() }

        ColumnLayout {
            id: controlsColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: root.immersive ? 12 : 0
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Item {
                    Layout.preferredWidth: Math.max(dayMenuButton.visible ? dayMenuButton.implicitWidth : 0, motionCount.implicitWidth)
                    implicitHeight: transport.height
                    Controls.Button {
                        id: dayMenuButton
                        objectName: "recordingDayMenu"
                        visible: root.immersive
                        anchors.verticalCenter: parent.verticalCenter
                        implicitHeight: 30
                        leftPadding: 12
                        rightPadding: 10
                        hoverEnabled: true
                        focusPolicy: Qt.NoFocus
                        contentItem: Row {
                            spacing: 6
                            MacText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.dayLabel(root.day)
                                color: "white"
                                font.weight: Font.DemiBold
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                textFormat: Text.PlainText
                                text: ui.iconChevronDown
                                font.family: ui.iconFont
                                font.pixelSize: 14
                                color: Qt.rgba(1, 1, 1, 0.7)
                            }
                        }
                        background: Rectangle {
                            radius: height / 2
                            color: dayMenuButton.hovered || dayMenu.opened ? Qt.rgba(1, 1, 1, 0.18) : Qt.rgba(1, 1, 1, 0.10)
                        }
                        onClicked: dayMenu.open()
                        PointerArea {}
                        Controls.Popup {
                            id: dayMenu
                            y: -height - 6
                            width: 200
                            height: Math.min(320, dayMenuList.contentHeight + 10)
                            padding: 5
                            background: Rectangle {
                                radius: 10
                                color: ui.menuBackground
                                border.width: 1
                                border.color: ui.separator
                            }
                            contentItem: ListView {
                                id: dayMenuList
                                clip: true
                                model: root.days
                                boundsBehavior: Flickable.StopAtBounds
                                delegate: Controls.ItemDelegate {
                                    id: dayRow
                                    required property string modelData
                                    width: ListView.view.width
                                    height: 28
                                    hoverEnabled: true
                                    contentItem: MacText {
                                        text: root.dayLabel(dayRow.modelData)
                                        color: dayRow.hovered ? ui.onAccent : ui.label
                                        font.weight: dayRow.modelData === root.day ? Font.DemiBold : Font.Normal
                                    }
                                    background: Rectangle { radius: 5; color: dayRow.hovered ? ui.accent : "transparent" }
                                    onClicked: { dayMenu.close(); root.selectDay(dayRow.modelData) }
                                }
                            }
                        }
                    }
                    MacText {
                        id: motionCount
                        objectName: "motionEventCount"
                        visible: !root.immersive && root.indexState === "ready"
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.motion.length ? strings.tn("recordings.motionCount", root.motion.length)
                            .arg(Commons.I18n.formatNumber(root.motion.length)) : strings.t("recordings.noMotion")
                        color: ui.secondaryLabel
                        font.pixelSize: ui.caption
                        font.weight: Font.Medium
                    }
                }
                Item { Layout.fillWidth: true }
                // One glass capsule: transport, then speed.
                Rectangle {
                    id: transport
                    implicitWidth: transportRow.implicitWidth + 16
                    implicitHeight: 40
                    radius: height / 2
                    color: root.immersive ? Qt.rgba(1, 1, 1, 0.06) : ui.fill
                    RowLayout {
                        id: transportRow
                        anchors.centerIn: parent
                        spacing: 2
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
                        Controls.Button {
                            id: playButton
                            objectName: "recordingPlay"
                            implicitWidth: 34
                            implicitHeight: 34
                            hoverEnabled: true
                            focusPolicy: Qt.NoFocus
                            enabled: root.canPlay
                            opacity: enabled ? 1 : 0.4
                            Accessible.name: tip.text
                            contentItem: Text {
                                textFormat: Text.PlainText
                                text: root.playState === "playing" || root.playState === "connecting" ? ui.iconPause : ui.iconPlay
                                font.family: ui.iconFont
                                font.pixelSize: 20
                                color: ui.onAccent
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                radius: width / 2
                                color: playButton.down ? Qt.darker(ui.label, 1.25) : ui.label
                                opacity: playButton.hovered ? 0.92 : 1
                            }
                            PanelToolTip {
                                id: tip
                                visible: playButton.hovered
                                text: (root.playState === "playing" ? strings.t("clip.pause") : strings.t("clip.resume")) + " (Space)"
                                fontSize: Style.font.caption
                            }
                            onClicked: { root.forceActiveFocus(); root.togglePlay() }
                            PointerArea {}
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
                        Rectangle { width: 1; height: 20; color: ui.separator; Layout.leftMargin: 4; Layout.rightMargin: 4 }
                        MacSegmented {
                            id: speedControl
                            objectName: "recordingSpeed"
                            model: root.speeds.map(function(rate) { return Commons.I18n.formatNumber(rate) + "×" })
                            tips: root.speeds.map(function(rate, i) {
                                return strings.t("recordings.speed").arg(Commons.I18n.formatNumber(rate)) + " (" + (i + 1) + ")" })
                            segmentNames: ["speed1", "speed15", "speed2", "speed4"]
                            autoSelect: false
                            currentIndex: root.speeds.indexOf(root.speed)
                            onActivated: function(index) { root.speed = root.speeds[index]; root.forceActiveFocus() }
                        }
                    }
                }
                Item { Layout.fillWidth: true }
                Item { Layout.preferredWidth: Math.max(dayMenuButton.visible ? dayMenuButton.implicitWidth : 0, motionCount.implicitWidth) }
            }

            Timeline {
                id: dayLine
                objectName: "dayTimeline"
                Layout.fillWidth: true
                from: 0
                to: root.dayLength
                tickEvery: 3 * 3600
                histogram: true
                showWindow: true
                tickLabel: function(value) { return root.clock(value, false).slice(0, 2) + "h" }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 4
                MacToolbarButton {
                    objectName: "recordingPrevHour"
                    glyph: ui.iconChevronLeft
                    tipText: strings.t("recordings.prevHour")
                    enabled: root.hourStart > 0
                    onClicked: root.stepHour(-1)
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
                    onClicked: root.stepHour(1)
                }
            }

            // Motion events: jump straight to one; hover shows its still when there is one.
            Item {
                Layout.fillWidth: true
                implicitHeight: 26
                visible: root.indexState === "ready" && root.motion.length > 0
                ListView {
                    id: motionList
                    objectName: "motionEvents"
                    anchors.fill: parent
                    orientation: ListView.Horizontal
                    spacing: 5
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    model: root.motion
                    currentIndex: root.motionIndex
                    highlightFollowsCurrentItem: false
                    onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Center)
                    onCountChanged: if (count > 0) Qt.callLater(function() {
                        motionList.positionViewAtIndex(Math.max(0, root.motionIndex), ListView.Center) })
                    WheelHandler {
                        acceptedDevices: PointerDevice.Mouse
                        onWheel: function(event) {
                            motionList.contentX = Math.max(0, Math.min(motionList.contentWidth - motionList.width,
                                motionList.contentX - event.angleDelta.y))
                        }
                    }
                    delegate: Controls.Button {
                        id: chip
                        required property var modelData
                        required property int index
                        readonly property bool current: index === root.motionIndex
                        implicitHeight: 26
                        leftPadding: 10
                        rightPadding: 10
                        hoverEnabled: true
                        focusPolicy: Qt.NoFocus
                        Accessible.name: chipText.text
                        contentItem: Text {
                            id: chipText
                            textFormat: Text.PlainText
                            text: root.chipLabels[chip.index] || root.clock(chip.modelData[0], false)
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
                        onHoveredChanged: {
                            if (hovered) chipPreview.show(chip, root.stillNear(chip.modelData[0], 20))
                            else chipPreview.hideFor(chip)
                        }
                        onClicked: { root.forceActiveFocus(); root.requestPlay(chip.modelData[0] - 3) }
                        PointerArea {}
                    }
                }
                // Fades hint that the row scrolls.
                Rectangle {
                    anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                    width: 24
                    visible: motionList.contentX > 2
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: root.immersive ? Qt.rgba(0.08, 0.08, 0.09, 1) : Commons.Color.popups.background }
                        GradientStop { position: 1; color: "transparent" }
                    }
                }
                Rectangle {
                    anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
                    width: 24
                    visible: motionList.contentX + motionList.width < motionList.contentWidth - 2
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: "transparent" }
                        GradientStop { position: 1; color: root.immersive ? Qt.rgba(0.08, 0.08, 0.09, 1) : Commons.Color.popups.background }
                    }
                }
            }
        }
    }

    // A still above a hovered motion chip.
    Rectangle {
        id: chipPreview
        objectName: "chipPreview"
        property var owner: null
        property string path: ""
        function show(item, stillPath) {
            owner = item
            path = stillPath
            if (!stillPath) return
            var at = item.mapToItem(root, item.width / 2, 0)
            x = Math.max(4, Math.min(root.width - width - 4, at.x - width / 2))
            y = Math.max(4, at.y - height - 6)
        }
        function hideFor(item) { if (owner === item) { owner = null; path = "" } }
        visible: path !== ""
        width: 176
        height: 104
        radius: 8
        color: "#0e0e10"
        border.width: 1
        border.color: ui.separator
        z: 20
        Image {
            anchors.fill: parent
            anchors.margins: 2
            source: chipPreview.path ? "file://" + chipPreview.path : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: 352
            sourceSize.height: 208
        }
    }

    // Days on the card: scrolls sideways (also with the wheel), with fades at the edges.
    component DayStrip: Item {
        implicitHeight: ui.controlHeight
        visible: root.days.length > 0
        ListView {
            id: dayStrip
            objectName: "recordingDays"
            anchors.fill: parent
            orientation: ListView.Horizontal
            spacing: 6
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.days
            WheelHandler {
                acceptedDevices: PointerDevice.Mouse
                onWheel: function(event) {
                    dayStrip.contentX = Math.max(0, Math.min(dayStrip.contentWidth - dayStrip.width,
                        dayStrip.contentX - event.angleDelta.y))
                }
            }
            delegate: MacButton {
                required property string modelData
                text: root.dayLabel(modelData)
                role: modelData === root.day ? "default" : "normal"
                onClicked: root.selectDay(modelData)
            }
        }
        Rectangle {
            anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
            width: 32
            visible: dayStrip.contentX + dayStrip.width < dayStrip.contentWidth - 2
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: "transparent" }
                GradientStop { position: 1; color: Commons.Color.popups.background }
            }
        }
        Rectangle {
            anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
            width: 32
            visible: dayStrip.contentX > 2
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: Commons.Color.popups.background }
                GradientStop { position: 1; color: "transparent" }
            }
        }
    }

    // A time track: recorded time as a soft bar, motion in orange (a density histogram
    // for the whole day), the hour shown below as a window, a white playhead with a knob.
    component Timeline: Item {
        id: line
        property real from: 0
        property real to: 3600
        property real tickEvery: 600
        property bool histogram: false
        property bool showWindow: false
        property var tickLabel: function(value) { return "" }
        readonly property real span: Math.max(1, to - from)
        readonly property real hoverAt: hover.hovered ? from + Math.max(0, Math.min(1, hover.point.position.x / width)) * span : -1
        function xOf(value) { return (value - from) / span * width }
        implicitHeight: 42

        Rectangle {
            id: track
            y: 4
            width: parent.width
            height: 22
            radius: 5
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
                    color: ui.alpha(ui.label, 0.14)
                }
            }
            Repeater {  // the whole day: motion per 10 minutes, as bars
                model: line.histogram ? root.density : []
                Rectangle {
                    required property int modelData
                    required property int index
                    visible: modelData > 0
                    x: line.xOf(index * 600) + 0.5
                    width: Math.max(1, line.xOf(600) - line.xOf(0) - 1)
                    height: Math.max(3, parent.height * Math.sqrt(modelData / root.densityMax))
                    y: parent.height - height
                    radius: 1
                    color: ui.systemOrange
                    opacity: 0.55 + 0.45 * modelData / root.densityMax
                }
            }
            Repeater {  // an hour: each motion recording
                model: line.histogram ? [] : root.motion
                Rectangle {
                    required property var modelData
                    visible: modelData[1] >= line.from && modelData[0] <= line.to
                    x: Math.max(0, line.xOf(modelData[0]))
                    width: Math.max(2, Math.min(line.width, line.xOf(modelData[1])) - x)
                    height: parent.height
                    color: ui.systemOrange
                }
            }
            Rectangle {  // which hour the close-up below shows
                visible: line.showWindow && root.indexState === "ready"
                x: line.xOf(root.hourStart)
                width: Math.max(2, line.xOf(root.hourStart + 3600) - x)
                height: parent.height
                color: Qt.rgba(1, 1, 1, 0.07)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.45)
                radius: 3
            }
            Rectangle {  // hover marker
                visible: line.hoverAt >= 0
                x: line.xOf(line.hoverAt)
                width: 1
                height: parent.height
                color: ui.alpha(ui.label, 0.7)
            }
        }
        Item {  // playhead: white, with a knob, overhanging the track
            visible: root.cursor >= 0 && root.position >= line.from && root.position <= line.to
            x: line.xOf(root.position)
            y: 0
            Rectangle { x: -1; y: 0; width: 2; height: track.height + 8; radius: 1; color: "white" }
            Rectangle {
                x: -5; y: -3
                width: 10; height: 10; radius: 5
                color: "white"
                border.width: 1
                border.color: Qt.rgba(0, 0, 0, 0.35)
            }
        }
        Repeater {
            model: Math.floor(line.span / line.tickEvery) + 1
            Text {
                required property int index
                readonly property real value: line.from + index * line.tickEvery
                x: Math.max(0, Math.min(line.width - width, line.xOf(value) - width / 2))
                y: track.y + track.height + 3
                textFormat: Text.PlainText
                text: line.tickLabel(value)
                font.family: ui.font
                font.pixelSize: ui.caption
                font.features: { "tnum": 1 }
                color: ui.secondaryLabel
            }
        }
        Rectangle {  // hover time
            visible: line.hoverAt >= 0
            x: Math.max(0, Math.min(line.width - width, line.xOf(line.hoverAt) - width / 2))
            y: track.y + track.height + 1
            width: hoverText.implicitWidth + 10
            height: 17
            radius: 4
            color: ui.menuBackground
            border.width: 1
            border.color: ui.separator
            MacText {
                id: hoverText
                anchors.centerIn: parent
                text: root.clock(line.hoverAt)
                font.pixelSize: ui.caption
                font.features: { "tnum": 1 }
            }
        }
        HoverHandler { id: hover }
        MouseArea {
            x: 0; y: 0; width: parent.width; height: track.y + track.height + 4
            cursorShape: Qt.PointingHandCursor
            onClicked: function(mouse) {
                root.forceActiveFocus()
                root.requestPlay(line.from + Math.max(0, Math.min(1, mouse.x / width)) * line.span)
            }
        }
    }

    // Text on a translucent capsule (status pill actions).
    component GlassPill: Controls.Button {
        id: glassPill
        implicitHeight: 26
        leftPadding: 12
        rightPadding: 12
        hoverEnabled: true
        focusPolicy: Qt.NoFocus
        Accessible.name: text
        contentItem: Text {
            textFormat: Text.PlainText
            text: glassPill.text
            font.family: ui.font
            font.pixelSize: ui.callout
            font.weight: Font.DemiBold
            color: "white"
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: height / 2
            color: glassPill.down ? Qt.rgba(1, 1, 1, 0.3) : glassPill.hovered ? Qt.rgba(1, 1, 1, 0.24) : Qt.rgba(1, 1, 1, 0.16)
        }
        PointerArea {}
    }
}
