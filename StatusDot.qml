import QtQuick
import qs.Commons

// Small connection indicator: green live, orange connecting, red offline.
Rectangle {
    id: dot
    property color tone: "grey"
    property bool pulsing: false
    implicitWidth: 8
    implicitHeight: 8
    radius: width / 2
    color: tone
    SequentialAnimation on opacity {
        running: dot.pulsing && dot.visible
        loops: Animation.Infinite
        NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
        NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
        onRunningChanged: if (!running) dot.opacity = 1
    }
}
