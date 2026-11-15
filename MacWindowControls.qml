import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui

// macOS window controls. Red closes, green toggles full screen; yellow
// (minimize) has no meaning for a bar viewer and is shown disabled, as macOS
// does for windows that cannot minimize. Glyphs appear while hovering the group.
Row {
    id: lights
    AppleStyle { id: ui }
    property bool zoomEnabled: true
    property bool zoomed: false
    property string closeTip: "Close"
    property string zoomTip: zoomed ? "Exit Full Screen" : "Enter Full Screen"
    signal closeRequested()
    signal zoomRequested()
    spacing: 8
    HoverHandler { id: groupHover }

    component Light: Controls.AbstractButton {
        id: light
        property color tone: "grey"
        property string glyph: ""
        property string tip: ""
        width: 12; height: 12
        hoverEnabled: true
        focusPolicy: Qt.TabFocus
        Accessible.name: tip
        PanelToolTip {
            visible: light.hovered && light.enabled && light.tip !== ""
            text: light.tip
            fontSize: Style.font.caption
        }
        background: Rectangle {
            radius: width / 2
            color: light.enabled ? (light.down ? Qt.darker(light.tone, 1.2) : light.tone) : ui.alpha(ui.label, 0.20)
            border.width: light.visualFocus ? 2 : 1
            border.color: light.visualFocus ? ui.alpha(ui.accent, 0.9) : Qt.rgba(0, 0, 0, 0.18)
        }
        contentItem: Text {
            textFormat: Text.PlainText
            text: light.glyph
            visible: groupHover.hovered && light.enabled
            font.family: ui.iconFont
            font.pixelSize: 9
            font.weight: Font.Bold
            color: Qt.rgba(0, 0, 0, 0.55)
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        PointerArea { visible: light.enabled }
    }

    Light {
        objectName: "closeButton"
        tone: ui.closeLight
        glyph: ui.iconClose
        tip: lights.closeTip
        onClicked: lights.closeRequested()
    }
    Light {
        objectName: "minimizeLight"
        enabled: false
    }
    Light {
        objectName: "zoomButton"
        tone: ui.zoomLight
        glyph: lights.zoomed ? ui.iconFullscreenExit : ui.iconFullscreen
        tip: lights.zoomTip
        enabled: lights.zoomEnabled
        onClicked: lights.zoomRequested()
    }
}
