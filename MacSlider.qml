import QtQuick
import QtQuick.Controls as Controls
import qs.Commons

// macOS slider: thin rounded track, accent fill, white knob with a soft shadow.
Controls.Slider {
    id: slider
    AppleStyle { id: ui }
    implicitHeight: 24
    hoverEnabled: true
    background: Rectangle {
        x: slider.leftPadding
        y: slider.topPadding + slider.availableHeight / 2 - height / 2
        width: slider.availableWidth
        height: 4
        radius: 2
        color: ui.fillHover
        Rectangle {
            width: slider.visualPosition * parent.width
            height: parent.height
            radius: 2
            color: ui.accent
        }
    }
    handle: Item {
        x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
        y: slider.topPadding + slider.availableHeight / 2 - height / 2
        implicitWidth: 20
        implicitHeight: 20
        Rectangle {
            anchors.fill: parent
            anchors.topMargin: 1
            anchors.bottomMargin: -1
            radius: width / 2
            color: Qt.rgba(0, 0, 0, 0.35)
        }
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: slider.pressed ? "#e6e6e9" : "#ffffff"
            border.width: slider.visualFocus ? 2 : 0
            border.color: ui.alpha(ui.accent, 0.8)
        }
    }
    PointerArea {}
}
