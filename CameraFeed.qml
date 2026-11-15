import QtQuick
import QtQuick.Controls
import QtQuick.Controls as Controls
import QtQuick.Layouts
import QtMultimedia
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// One player and recovery loop per tile: a stalled camera cannot stop its peer.
Rectangle {
    id: root
    Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
    property var camera: ({url: "", username: "", password: ""})
    property bool streaming: false
    property bool compact: false
    property bool fullscreen: false
    property string videoStyle: "theme"
    property int tintStrength: 35
    property int pixelSize: 3
    property string overlayStyle: "default"
    property string message: ""
    property string playbackMessage: ""
    property bool receivedFrame: false
    property double framesReceived: 0
    property int retryAttempt: 0
    property bool changingPlayback: false
    readonly property bool live: streaming && frameWatchdog.running
        && player.playbackState === MediaPlayer.PlayingState
    readonly property string sourceUrl: streamUrl()
    signal audioRequested()
    signal fullscreenRequested()

    function mute() { cameraAudio.muted = true }
    function toggleAudio() {
        if (streaming && player.hasAudio) cameraAudio.muted = !cameraAudio.muted
    }
    function status() {
        return {id: camera.id || "", name: camera.name || "Camera",
            streaming: streaming, live: live, receivedFrame: receivedFrame,
            framesReceived: framesReceived, timeoutRunning: connectionTimeout.running,
            playing: player.playbackState === MediaPlayer.PlayingState,
            hasAudio: player.hasAudio, muted: cameraAudio.muted,
            reconnectPending: reconnectTimer.running, retryAttempt: retryAttempt,
            retryDelay: reconnectTimer.interval, message: playbackMessage}
    }
    function stop() {
        reconnectTimer.stop()
        retryAttempt = 0
        frameWatchdog.stop()
        mute()
        connectionTimeout.stop()
        changingPlayback = true
        player.stop()
        player.source = ""
        changingPlayback = false
    }
    onStreamingChanged: { if (streaming) play(); else stop() }
    onSourceUrlChanged: { mute(); if (streaming) play() }
    Component.onDestruction: stop()
    function streamUrl() {
        var url = camera.url || ""
        var split = url.indexOf("://") + 3
        var auth = camera.username ? encodeURIComponent(camera.username) + ":" + encodeURIComponent(camera.password) + "@" : ""
        return url.slice(0, split) + auth + url.slice(split)
    }
    function play(resetRetry) {
        if (!streaming) return
        reconnectTimer.stop()
        if (resetRetry !== false) retryAttempt = 0
        frameWatchdog.stop()
        connectionTimeout.stop()
        changingPlayback = true
        player.stop()
        player.source = ""
        receivedFrame = false
        framesReceived = 0
        playbackMessage = "Connecting…"
        player.source = streamUrl()
        changingPlayback = false
        connectionTimeout.restart()
        player.play()
    }
    function scheduleReconnect(reason) {
        if (!streaming || changingPlayback || reconnectTimer.running) return
        frameWatchdog.stop()
        connectionTimeout.stop()
        changingPlayback = true
        player.stop()
        player.source = ""
        changingPlayback = false
        reconnectTimer.interval = Math.min(30000, 2000 * Math.pow(2, retryAttempt))
        retryAttempt = Math.min(retryAttempt + 1, 5)
        playbackMessage = reason + " Retrying in " + reconnectTimer.interval / 1000 + "s…"
        reconnectTimer.start()
    }
    MediaPlayer {
        id: player
        videoOutput: video
        audioOutput: AudioOutput {
            id: cameraAudio
            muted: true
            volume: 1.0
        }
        onErrorOccurred: {
            root.scheduleReconnect("Unable to connect.")
        }
        onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.EndOfMedia) {
                root.scheduleReconnect("Stream ended.")
            }
        }
        onPlaybackStateChanged: {
            if (playbackState !== MediaPlayer.PlayingState) {
                frameWatchdog.stop()
                if (root.receivedFrame) root.scheduleReconnect("Stream interrupted.")
            }
        }
    }
    Connections {
        target: video.videoSink
        function onVideoFrameChanged() {
            // Live RTSP feeds can render indefinitely without BufferedMedia.
            // A positive video size excludes the empty frame emitted on stop.
            if (!root.streaming || root.changingPlayback || player.playbackState !== MediaPlayer.PlayingState
                || video.videoSink.videoSize.width <= 0 || video.videoSink.videoSize.height <= 0) return
            root.framesReceived += 1
            reconnectTimer.stop()
            root.retryAttempt = 0
            frameWatchdog.restart()
            if (!root.receivedFrame) {
                root.receivedFrame = true
                connectionTimeout.stop()
                root.playbackMessage = ""
            }
        }
    }
    Timer {
        id: reconnectTimer
        interval: 2000
        onTriggered: root.play(false)
    }
    Timer {
        id: frameWatchdog
        interval: 5000
        onTriggered: root.scheduleReconnect("Video stalled.")
    }
    Timer {
        id: connectionTimeout
        interval: 20000
        onTriggered: {
            if (!root.streaming || root.receivedFrame) return
            root.scheduleReconnect("Connection timed out.")
        }
    }

    color: "#080b10"
    border.width: 1
    border.color: Commons.Color.accent
    clip: true
    VideoOutput {
        id: video
        anchors.fill: parent
        anchors.margins: 1
        fillMode: VideoOutput.PreserveAspectFit
    }
    VideoEffect {
        objectName: "videoEffect"
        anchors.fill: video
        sourceItem: video
        active: root.streaming
        style: root.videoStyle
        strength: root.tintStrength / 100
        pixelSize: root.pixelSize
    }
    // Keep controls readable over both light and dark video.
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 1
        height: 88
        gradient: Gradient {
            GradientStop { position: 0; color: Qt.rgba(Commons.Color.background.r, Commons.Color.background.g, Commons.Color.background.b, 0) }
            GradientStop { position: 1; color: Qt.rgba(Commons.Color.background.r, Commons.Color.background.g, Commons.Color.background.b, 0.75) }
        }
    }
    VideoOverlay {
        id: cameraOverlay
        objectName: "videoOverlay"
        x: video.x + (video.contentRect.width > 0 ? video.contentRect.x : 0)
        y: video.y + (video.contentRect.height > 0 ? video.contentRect.y : 0)
        width: video.contentRect.width > 0 ? video.contentRect.width : video.width
        height: video.contentRect.height > 0 ? video.contentRect.height : video.height
        active: root.streaming
        mode: root.overlayStyle
        cameraName: root.camera.name || "Camera"
        live: root.live
        framesReceived: root.framesReceived
        rightHeaderSpace: audioWaveform.width + 8
    }
    AudioWaveform {
        id: audioWaveform
        objectName: "audioButton"
        readonly property real videoWidth: cameraOverlay.width > 0 ? cameraOverlay.width : video.width
        x: (cameraOverlay.width > 0 ? cameraOverlay.x : video.x)
            + videoWidth - feedControls.sideInset - width
        y: (cameraOverlay.height > 0 ? cameraOverlay.y : video.y) + feedControls.overlayInset + 8
        width: Math.min(104, Math.max(0, videoWidth - feedControls.sideInset * 2) * 0.3)
        audioAvailable: root.streaming && player.hasAudio
        audioMuted: cameraAudio.muted
        onClicked: root.audioRequested()
    }
    Label {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        width: parent.width - 48
        text: root.playbackMessage
        visible: text !== ""
        color: "white"
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        padding: 12
        background: Rectangle { color: "#dd080b10"; radius: 8 }
    }
    Label {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: feedControls.top
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        anchors.bottomMargin: 6
        text: root.message
        visible: text !== ""
        color: "#ffd2d2"
        wrapMode: Text.WordWrap
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
    }
    RowLayout {
        id: feedControls
        readonly property real overlayInset: cameraOverlay.item && cameraOverlay.item.inset !== undefined
            ? cameraOverlay.item.inset : 0
        readonly property real sideInset: Math.max(12, overlayInset + 6)
        anchors.left: cameraOverlay.width > 0 ? cameraOverlay.left : video.left
        anchors.right: cameraOverlay.width > 0 ? cameraOverlay.right : video.right
        anchors.bottom: cameraOverlay.height > 0 ? cameraOverlay.bottom : video.bottom
        anchors.leftMargin: sideInset
        anchors.rightMargin: sideInset
        anchors.bottomMargin: overlayInset + 12
        spacing: 6
        Item { Layout.fillWidth: true }
        FeedButton {
            objectName: "fullscreenButton"
            text: "⛶"
            font.family: "JetBrainsMono Nerd Font"
            Accessible.name: root.fullscreen ? "Exit fullscreen" : root.compact ? strings.t("feed.enlarge") : "Fullscreen"
            tipText: root.fullscreen ? "Exit fullscreen" : root.compact ? strings.t("feed.enlarge") : "Fullscreen"
            checked: root.fullscreen
            onClicked: root.fullscreenRequested()
            PointerArea {}
        }
    }

    Label {
        textFormat: Text.PlainText
        objectName: "feedName"
        visible: root.compact && root.overlayStyle !== "hacker"
        x: cameraOverlay.x + feedControls.sideInset + 2
        y: cameraOverlay.y + feedControls.overlayInset + 8
        width: Math.min(implicitWidth, Math.max(0, cameraOverlay.width * 0.55))
        text: root.camera.name || "Camera"
        elide: Text.ElideRight
        color: "white"
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.weight: Font.DemiBold
        padding: 7
        background: Rectangle { radius: 7; color: "#b3080b10" }
    }
    component FeedButton: Controls.Button {
        id: feedButton
        property string tipText: ""
        implicitWidth: 36
        implicitHeight: 36
        padding: 0
        font.pixelSize: 18
        hoverEnabled: true
        PanelToolTip {
            visible: feedButton.hovered && feedButton.tipText !== ""
            text: feedButton.tipText
            fontSize: Style.font.caption
        }
        contentItem: Text {
            textFormat: Text.PlainText
            text: parent.text
            font: parent.font
            color: !feedButton.enabled ? Commons.Color.muted
                : feedButton.checked || feedButton.hovered || feedButton.activeFocus ? Commons.Color.accent : Commons.Color.foreground
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: 18
            color: feedButton.hovered || feedButton.checked
                ? Qt.rgba(0, 0, 0, 0.35)
                : Qt.rgba(0, 0, 0, 0.22)
            border.width: 1
            border.color: !feedButton.enabled ? Commons.Color.muted
                : feedButton.checked || feedButton.hovered || feedButton.activeFocus ? Commons.Color.accent : Qt.rgba(1, 1, 1, 0.12)
        }
        PointerArea {}
    }
}
