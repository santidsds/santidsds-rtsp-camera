import QtQuick
import qs.Commons
import qs.Commons as Commons

Item {
    id: root
    property string profile: "hacker"
    readonly property bool hacker: profile === "hacker"
    property string cameraName: "Camera"
    property bool live: false
    property real rightHeaderSpace: 0
    property double framesReceived: 0
    property double sampledFrames: 0
    property int tick: 0
    readonly property color ink: Commons.Color.accent
    readonly property color cornerColor: live ? Commons.Color.accent : "#ff4545"
    readonly property int inset: Math.max(7, Math.min(12, width / 24))
    readonly property int contentInset: inset + 6
    property real scanProgress: 0
    readonly property bool detailed: width >= 300 && height >= 260
    readonly property string frameHex: Math.floor(sampledFrames).toString(16).toUpperCase().padStart(8, "0")
    clip: true

    // Stream watchdog restarts briefly toggle live on every received frame.
    // Pause/resume preserves position through those toggles; restarting would freeze it.
    SequentialAnimation {
        running: root.visible && root.hacker
        paused: running && !root.live
        loops: Animation.Infinite
        NumberAnimation { target: root; property: "scanProgress"; from: 0; to: 1; duration: 3000; easing.type: Easing.Linear }
        NumberAnimation { target: root; property: "scanProgress"; from: 1; to: 0; duration: 3000; easing.type: Easing.Linear }
    }

    // Small decorations share an 8 Hz clock. Closing the loader releases both clocks.
    Timer {
        interval: 125
        repeat: true
        running: root.visible && root.profile !== "default"
        onTriggered: {
            root.tick = (root.tick + 1) % 4096
            if (root.tick % 8 === 0) root.sampledFrames = root.framesReceived
        }
    }
    onLiveChanged: sampledFrames = framesReceived
    Component.onCompleted: sampledFrames = framesReceived

    Repeater {
        model: root.hacker ? Math.min(180, Math.floor(root.height / 4)) : 0
        Rectangle {
            required property int index
            y: index * Math.max(4, root.height / 180)
            width: root.width; height: 1
            color: root.ink
            opacity: 0.20
        }
    }
    // A narrow sweep adds motion without covering the center with UI panels.
    Rectangle {
        objectName: "terminalScanBand"
        visible: root.hacker
        x: root.inset
        y: root.inset + root.scanProgress * Math.max(0, root.height - root.inset * 2 - height)
        width: Math.max(0, root.width - root.inset * 2)
        height: Math.min(28, Math.max(0, root.height - root.inset * 2))
        gradient: Gradient {
            GradientStop { position: 0; color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0) }
            GradientStop { position: 0.5; color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.24) }
            GradientStop { position: 1; color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0) }
        }
        Rectangle { y: Math.floor(parent.height / 2); width: parent.width; height: 1; color: root.ink; opacity: 0.85 }
    }
    Rectangle {
        visible: root.hacker
        x: root.inset; y: root.inset
        width: Math.max(0, root.width - root.inset * 2)
        height: Math.max(0, root.height - root.inset * 2)
        color: "transparent"
        border.color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.35)
    }
    Repeater {
        model: 4
        Item {
            required property int index
            readonly property bool rightSide: index % 2 === 1
            readonly property bool bottomSide: index >= 2
            x: rightSide ? root.width - root.inset - width : root.inset
            y: bottomSide ? root.height - root.inset - height : root.inset
            width: Math.min(44, root.width / 5)
            height: Math.min(28, root.height / 6)
            Rectangle { objectName: "overlayCorner"; y: parent.bottomSide ? parent.height - 2 : 0; width: parent.width; height: 2; color: root.cornerColor }
            Rectangle { x: parent.rightSide ? parent.width - 2 : 0; width: 2; height: parent.height; color: root.cornerColor }
        }
    }
    Rectangle {
        id: header
        visible: root.hacker
        x: root.contentInset; y: root.inset + 5
        width: Math.max(0, root.width - x * 2)
        height: root.height >= 160 ? 48 : 34
        color: "transparent"
        Rectangle { width: 3; height: parent.height; color: root.ink }
        TerminalText {
            x: 10; y: 6
            width: Math.max(0, parent.width - 32 - root.rightHeaderSpace)
            text: ">_ " + root.cameraName.toUpperCase()
            font.pixelSize: 12
            font.bold: true
            font.letterSpacing: 1.2
        }
        TerminalText {
            x: 10; y: 25
            visible: root.height >= 160
            width: Math.max(0, parent.width - 32 - root.rightHeaderSpace)
            text: (root.live ? "LINK UP" : "LINK LOST") + " / RX " + root.frameHex
            color: root.live ? root.ink : Commons.Color.urgent
            font.pixelSize: 9
        }

    }
    // Edge activity indicators and a blinking block cursor share the same clock.
    Repeater {
        model: root.profile !== "default" && root.height >= 100 ? 12 : 0
        Rectangle {
            required property int index
            objectName: "overlayActivityDot"
            x: root.width - root.inset - 7
            y: root.height / 2 + (index - 6) * 6
            width: 4; height: 3
            color: root.ink
            opacity: root.live && index === (root.tick % 22 <= 11 ? root.tick % 22 : 22 - root.tick % 22) ? 1 : 0.20
        }
    }
    Rectangle {
        visible: root.hacker && (!root.live || root.tick % 8 < 4)
        x: header.x + header.width - 12
        y: header.y + header.height - 14
        width: 6; height: 9
        color: root.ink
    }
    Rectangle {
        objectName: "terminalConsole"
        visible: root.profile !== "default" && root.detailed
        x: root.contentInset
        y: root.height - height - root.inset - 12
        width: Math.max(0, Math.min(280, root.width - root.contentInset * 2 - 46))
        height: 59
        color: Qt.rgba(Commons.Color.background.r, Commons.Color.background.g, Commons.Color.background.b, 0.39)
        Rectangle { width: 2; height: parent.height; color: root.ink }
        Column {
            x: 10; y: 7
            spacing: 3
            TerminalText { text: "$ monitor --stream"; font.bold: true }
            TerminalText { text: root.live ? "[video] frames arriving" : "[video] waiting for signal" }
            TerminalText { text: "[frame] 0x" + root.frameHex + (root.live && root.tick % 8 < 4 ? " █" : "  ") }
        }
    }
    component TerminalText: Text {
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: 10
        color: root.ink
        style: Text.Outline
        styleColor: "#80000000"
        textFormat: Text.PlainText
        elide: Text.ElideRight
    }
}
