import QtQuick
import QtQuick.Controls as Controls
import qs.Commons

// macOS push button. role: "normal", "default" (accent), "destructive", "plain".
Controls.Button {
    id: button
    AppleStyle { id: ui }
    property string role: "normal"
    readonly property bool filled: role === "default" || (role === "destructive" && checked)
    readonly property color tone: role === "destructive" ? ui.systemRed : ui.accent
    implicitHeight: ui.controlHeight
    leftPadding: role === "plain" ? 8 : 14
    rightPadding: role === "plain" ? 8 : 14
    topPadding: 0
    bottomPadding: 0
    hoverEnabled: true
    focusPolicy: Qt.TabFocus
    background: Rectangle {
        radius: ui.controlRadius
        color: button.filled
            ? (button.down ? Qt.darker(button.tone, 1.15) : button.hovered ? Qt.lighter(button.tone, 1.12) : button.tone)
            : button.role === "plain"
                ? (button.down ? ui.fillPressed : button.hovered ? ui.fill : "transparent")
                : (button.down ? ui.fillPressed : button.hovered ? ui.fillHover : ui.fill)
        border.width: button.visualFocus ? 2 : button.filled || button.role === "plain" ? 0 : 1
        border.color: button.visualFocus ? ui.alpha(ui.accent, 0.8) : ui.groupBorder
        opacity: button.enabled ? 1 : 0.5
        Behavior on color { ColorAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
    }
    contentItem: Text {
        textFormat: Text.PlainText
        text: button.text
        font.family: ui.font
        font.pixelSize: ui.body
        font.weight: button.role === "default" ? Font.DemiBold : Font.Medium
        color: button.filled ? (button.role === "destructive" ? "#ffffff" : ui.onAccent)
            : button.role === "destructive" ? ui.systemRed : ui.label
        opacity: button.enabled ? 1 : 0.6
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
    PointerArea {}
}
