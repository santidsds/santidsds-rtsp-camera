import QtQuick
import QtQuick.Controls
import QtQuick.Controls as Controls
import QtQuick.Layouts
import QtMultimedia
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// One player and recovery loop per tile: a stalled camera cannot stop its peer.
// The visible tile hugs the stream's aspect ratio, so the rounded video is the
// tile itself rather than a letterboxed box.
Item {
    id: root
    AppleStyle { id: ui }
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
    readonly property bool connecting: streaming && !live && !reconnectTimer.running
    readonly property string connectionState: !streaming ? "idle" : live ? "live"
        : reconnectTimer.running ? "offline" : "connecting"
    readonly property color statusColor: connectionState === "live" ? ui.systemGreen
        : connectionState === "offline" ? ui.systemRed
        : connectionState === "connecting" ? ui.systemOrange : ui.tertiaryLabel
    // Last known stream shape; kept across reconnects so the tile doesn't jump.
    property real aspect: 16 / 9
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

    Item {
        id: frame
        objectName: "videoFrame"
        anchors.centerIn: parent
        width: Math.max(1, Math.min(root.width, root.height * root.aspect))
        height: Math.max(1, width / root.aspect)
        layer.enabled: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: frameMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
        }
        Rectangle {
            anchors.fill: parent
            color: "#0e0e10"
        }
        Text {
            anchors.centerIn: parent
            visible: !root.receivedFrame && root.playbackMessage === ""
            textFormat: Text.PlainText
            text: ui.iconCamera
            font.family: ui.iconFont
            font.pixelSize: Math.min(56, frame.height / 4)
            color: Qt.rgba(1, 1, 1, 0.08)
        }
        VideoOutput {
            id: video
            anchors.fill: parent
            fillMode: VideoOutput.PreserveAspectFit
            onSourceRectChanged: {
                if (sourceRect.width > 0 && sourceRect.height > 0)
                    root.aspect = Math.max(0.5, Math.min(3.5, sourceRect.width / sourceRect.height))
            }
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
        // Soft scrims keep glass controls legible over bright video.
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Math.min(72, parent.height / 3)
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0) }
                GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.32) }
            }
        }
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Math.min(56, parent.height / 4)
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.22) }
                GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0) }
            }
        }
        VideoOverlay {
            id: cameraOverlay
            objectName: "videoOverlay"
            x: video.contentRect.width > 0 ? video.contentRect.x : 0
            y: video.contentRect.height > 0 ? video.contentRect.y : 0
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
            x: cameraOverlay.x + cameraOverlay.width - feedControls.sideInset - width
            y: cameraOverlay.y + feedControls.overlayInset + 10
            audioAvailable: root.streaming && player.hasAudio
            audioMuted: cameraAudio.muted
            onClicked: root.audioRequested()
        }
        // Connection progress: a glass capsule with a spinner while connecting.
        // Sized from the frame only: binding to its own contents would loop.
        Rectangle {
            id: messageCapsule
            objectName: "playbackMessage"
            readonly property real maxWidth: Math.max(0, frame.width - 32)
            anchors.centerIn: parent
            visible: root.playbackMessage !== ""
            width: Math.min(maxWidth, messageRow.implicitWidth + 28)
            height: messageRow.implicitHeight + 16
            radius: height / 2
            color: ui.glass
            border.width: 1
            border.color: ui.glassBorder
            Row {
                id: messageRow
                anchors.centerIn: parent
                spacing: 8
                Text {
                    id: spinner
                    visible: root.connecting
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: ui.iconLoading
                    font.family: ui.iconFont
                    font.pixelSize: 14
                    color: "white"
                    RotationAnimator on rotation {
                        running: spinner.visible && root.visible
                        from: 0; to: 360
                        duration: 900
                        loops: Animation.Infinite
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, Math.max(0, messageCapsule.maxWidth - 28 - (spinner.visible ? spinner.width + 8 : 0)))
                    textFormat: Text.PlainText
                    text: root.playbackMessage
                    font.family: ui.font
                    font.pixelSize: ui.callout
                    font.weight: Font.Medium
                    color: "white"
                    elide: Text.ElideRight
                }
            }
        }
        Rectangle {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.leftMargin: feedControls.sideInset
            anchors.bottomMargin: feedControls.overlayInset + 12
            visible: root.message !== ""
            width: Math.min(errorText.implicitWidth + 24, parent.width - feedControls.sideInset * 2 - 48)
            height: errorText.implicitHeight + 12
            radius: 8
            color: ui.glass
            border.width: 1
            border.color: ui.alpha(ui.systemRed, 0.5)
            Text {
                id: errorText
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                textFormat: Text.PlainText
                text: root.message
                font.family: ui.font
                font.pixelSize: ui.callout
                color: "#ffd0cc"
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
            }
        }
        RowLayout {
            id: feedControls
            readonly property real overlayInset: cameraOverlay.item && cameraOverlay.item.inset !== undefined
                && root.overlayStyle !== "default" ? cameraOverlay.item.inset : 0
            readonly property real sideInset: Math.max(12, overlayInset + 6)
            anchors.left: cameraOverlay.left
            anchors.right: cameraOverlay.right
            anchors.bottom: cameraOverlay.bottom
            anchors.leftMargin: sideInset
            anchors.rightMargin: sideInset
            anchors.bottomMargin: overlayInset + 12
            spacing: 6
            Item { Layout.fillWidth: true }
            FeedButton {
                objectName: "fullscreenButton"
                text: root.fullscreen ? ui.iconFullscreenExit : ui.iconFullscreen
                Accessible.name: tipText
                tipText: root.fullscreen ? "Exit Full Screen" : root.compact ? strings.t("feed.enlarge") : "Enter Full Screen"
                checked: root.fullscreen
                onClicked: root.fullscreenRequested()
            }
        }
        // Camera name and connection dot, top-left, when several tiles share the view.
        Rectangle {
            objectName: "feedNamePill"
            visible: root.compact && root.overlayStyle !== "hacker"
            x: cameraOverlay.x + feedControls.sideInset
            y: cameraOverlay.y + feedControls.overlayInset + 10
            width: Math.min(nameRow.implicitWidth + 22, Math.max(0, cameraOverlay.width * 0.6))
            height: 30
            radius: height / 2
            color: ui.glass
            border.width: 1
            border.color: ui.glassBorder
            Row {
                id: nameRow
                anchors.left: parent.left
                anchors.leftMargin: 11
                anchors.verticalCenter: parent.verticalCenter
                spacing: 7
                StatusDot {
                    anchors.verticalCenter: parent.verticalCenter
                    tone: root.statusColor
                    pulsing: root.connecting
                }
                Text {
                    objectName: "feedName"
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, Math.max(0, cameraOverlay.width * 0.6 - 40))
                    textFormat: Text.PlainText
                    text: root.camera.name || "Camera"
                    elide: Text.ElideRight
                    color: "white"
                    font.family: ui.font
                    font.pixelSize: ui.callout
                    font.weight: Font.DemiBold
                }
            }
        }
    }
    Item {
        id: frameMask
        anchors.fill: frame
        visible: false
        layer.enabled: true
        Rectangle {
            anchors.fill: parent
            radius: ui.videoRadius
        }
    }
    // Hairline edge so dark video still reads as a surface on dark glass.
    Rectangle {
        objectName: "videoHairline"
        anchors.fill: frame
        radius: ui.videoRadius
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.09)
    }
    component FeedButton: Controls.Button {
        id: feedButton
        property string tipText: ""
        implicitWidth: 30
        implicitHeight: 30
        padding: 0
        hoverEnabled: true
        focusPolicy: Qt.TabFocus
        PanelToolTip {
            visible: feedButton.hovered && feedButton.tipText !== ""
            text: feedButton.tipText
            fontSize: Style.font.caption
        }
        contentItem: Text {
            textFormat: Text.PlainText
            text: feedButton.text
            font.family: ui.iconFont
            font.pixelSize: 16
            color: "white"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: width / 2
            color: feedButton.down ? Qt.rgba(0, 0, 0, 0.7) : feedButton.hovered ? ui.glassHover : ui.glass
            border.width: feedButton.visualFocus ? 2 : 1
            border.color: feedButton.visualFocus ? ui.alpha(ui.accent, 0.9) : ui.glassBorder
        }
        PointerArea {}
    }
}
