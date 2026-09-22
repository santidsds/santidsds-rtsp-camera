import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui

Controls.Button {
    id: root
    property bool audioAvailable: false
    property bool audioMuted: true
    property int tick: 0
    implicitWidth: 104
    implicitHeight: 34
    padding: 3
    enabled: audioAvailable
    hoverEnabled: true
    Accessible.name: !audioAvailable ? "No audio track"
        : audioMuted ? "Unmute camera audio" : "Mute camera audio"
    PanelToolTip {
        visible: root.hovered
        text: !root.audioAvailable ? "No audio"
            : root.audioMuted ? "Unmute" : "Mute"
        fontSize: Style.font.caption
    }

    // The waveform is simulated. Its clock is independent of video-frame status.
    Timer {
        interval: 125
        repeat: true
        running: root.visible
        onTriggered: root.tick = (root.tick + 1) % 4096
    }
    background: Rectangle {
        color: "transparent"
        border.width: root.activeFocus ? 2 : root.hovered ? 1 : 0
        border.color: Color.accent
    }
    contentItem: Item {
        id: bars
        Repeater {
            model: 21
            Rectangle {
                required property int index
                x: index * bars.width / 21
                y: (bars.height - height) / 2
                width: Math.max(1, bars.width / 21 - 2)
                height: 3 + 25 * Math.abs(Math.sin(index * 0.73 + root.tick * 0.24)
                    * Math.cos(index * 0.21 - root.tick * 0.155))
                color: Color.accent
                opacity: !root.audioAvailable ? 0.25 : root.audioMuted ? 0.45 : 0.9
            }
        }
        Rectangle {
            visible: root.audioMuted
            anchors.centerIn: parent
            width: parent.width; height: 1
            rotation: -12
            color: Color.accent
            opacity: root.audioAvailable ? 1 : 0.35
        }
    }
    PointerArea {}
}
