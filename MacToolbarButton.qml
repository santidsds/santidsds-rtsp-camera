import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui

// Borderless macOS toolbar button: an SF Symbol-sized glyph with a hover fill.
Controls.Button {
    id: button
    AppleStyle { id: ui }
    property string glyph: ""
    property string tipText: ""
    property int iconSize: 16
    implicitWidth: ui.controlHeight + (text !== "" ? 0 : 2)
    implicitHeight: ui.controlHeight
    padding: 0
    hoverEnabled: true
    focusPolicy: Qt.TabFocus
    Accessible.name: tipText
    PanelToolTip {
        visible: button.hovered && button.tipText !== ""
        text: button.tipText
        fontSize: Style.font.caption
    }
    background: Rectangle {
        radius: ui.controlRadius
        color: button.down ? ui.fillPressed
            : button.checked ? ui.fillHover
            : button.hovered ? ui.fill : "transparent"
        border.width: button.visualFocus ? 2 : 0
        border.color: ui.alpha(ui.accent, 0.8)
        Behavior on color { ColorAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
    }
    contentItem: Text {
        textFormat: Text.PlainText
        text: button.glyph
        font.family: ui.iconFont
        font.pixelSize: button.iconSize
        color: !button.enabled ? ui.tertiaryLabel
            : button.checked ? ui.label : ui.secondaryLabel
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
    PointerArea {}
}
