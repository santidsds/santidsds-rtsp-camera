import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Glass speaker button. While audio plays it widens to show level bars.
Controls.Button {
    id: root
    AppleStyle { id: ui }
    property bool audioAvailable: false
    property bool audioMuted: true
    readonly property bool playing: audioAvailable && !audioMuted
    property int tick: 0
    implicitWidth: playing ? 62 : 30
    implicitHeight: 30
    padding: 0
    enabled: audioAvailable
    hoverEnabled: true
    focusPolicy: Qt.TabFocus
    Behavior on implicitWidth { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
    Accessible.name: !audioAvailable ? "No audio track"
        : audioMuted ? "Unmute camera audio" : "Mute camera audio"
    PanelToolTip {
        visible: root.hovered
        text: !root.audioAvailable ? "No audio"
            : root.audioMuted ? "Unmute" : "Mute"
        fontSize: Style.font.caption
    }

    // The level bars are simulated; they only move while sound is playing.
    Timer {
        interval: 125
        repeat: true
        running: root.visible && root.playing
        onTriggered: root.tick = (root.tick + 1) % 4096
    }
    background: Rectangle {
        radius: height / 2
        color: root.hovered && root.enabled ? ui.glassHover : ui.glass
        border.width: root.visualFocus ? 2 : 1
        border.color: root.visualFocus ? ui.alpha(ui.accent, 0.9) : ui.glassBorder
    }
    contentItem: Item {
        Row {
            anchors.centerIn: parent
            spacing: 5
            Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.playing ? ui.iconVolume : ui.iconVolumeOff
                font.family: ui.iconFont
                font.pixelSize: 15
                color: "white"
                opacity: root.audioAvailable ? 1 : 0.45
            }
            Row {
                id: bars
                visible: root.playing
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                Repeater {
                    model: 5
                    Rectangle {
                        required property int index
                        anchors.verticalCenter: parent.verticalCenter
                        width: 2
                        height: 3 + 9 * Math.abs(Math.sin(index * 0.9 + root.tick * 0.35)
                            * Math.cos(index * 0.37 - root.tick * 0.21))
                        radius: 1
                        color: "white"
                    }
                }
            }
        }
    }
    PointerArea { visible: root.enabled }
}
