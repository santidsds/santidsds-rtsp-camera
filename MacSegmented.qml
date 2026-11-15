import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui

// macOS segmented control with a sliding selection thumb.
// Segments share one width; set Layout.fillWidth to stretch them.
Item {
    id: control
    AppleStyle { id: ui }
    property var model: []
    property var icons: []
    property var tips: []
    property var segmentNames: []
    property bool iconOnly: false
    // false: the owner keeps currentIndex bound and reacts to activated().
    property bool autoSelect: true
    property int currentIndex: 0
    readonly property int count: model ? model.length : 0
    readonly property real segmentWidth: count > 0 ? (width - 4) / count : 0
    signal activated(int index)

    FontMetrics { id: metrics; font.family: ui.font; font.pixelSize: ui.callout; font.weight: Font.DemiBold }
    readonly property real widestSegment: {
        var widest = 0
        for (var i = 0; i < count; i++) {
            var label = iconOnly ? "" : String(model[i])
            var width = (label ? metrics.advanceWidth(label) : 0)
                + (icons[i] ? 18 + (label ? 6 : 0) : 0)
            widest = Math.max(widest, width)
        }
        return widest + (iconOnly ? 14 : 22)
    }
    implicitWidth: count * widestSegment + 4
    implicitHeight: ui.controlHeight

    Rectangle {
        anchors.fill: parent
        radius: ui.controlRadius
        color: ui.fill
        border.width: 1
        border.color: ui.alpha(ui.label, 0.04)
    }
    Rectangle {
        id: thumb
        objectName: "segmentThumb"
        visible: control.currentIndex >= 0 && control.currentIndex < control.count
        x: 2 + control.currentIndex * control.segmentWidth
        y: 2
        width: control.segmentWidth
        height: control.height - 4
        radius: ui.controlRadius - 2
        color: ui.alpha(ui.label, 0.20)
        border.width: 1
        border.color: ui.alpha(ui.label, 0.07)
        Behavior on x { NumberAnimation { duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
    }
    Row {
        x: 2; y: 2
        height: control.height - 4
        Repeater {
            model: control.count
            Controls.AbstractButton {
                id: segment
                required property int index
                readonly property bool selected: index === control.currentIndex
                objectName: control.segmentNames[index] || ""
                width: control.segmentWidth
                height: parent.height
                text: String(control.model[index])
                checkable: false
                hoverEnabled: true
                focusPolicy: Qt.TabFocus
                Accessible.name: control.tips[index] || text
                Accessible.role: Accessible.PageTab
                PanelToolTip {
                    visible: segment.hovered && !!control.tips[segment.index]
                    text: control.tips[segment.index] || ""
                    fontSize: Style.font.caption
                }
                background: Rectangle {
                    radius: ui.controlRadius - 2
                    color: !segment.selected && segment.hovered ? ui.alpha(ui.label, 0.06) : "transparent"
                    border.width: segment.visualFocus ? 2 : 0
                    border.color: ui.alpha(ui.accent, 0.8)
                }
                contentItem: Item {
                    Row {
                        anchors.centerIn: parent
                        spacing: 6
                        Text {
                            visible: !!control.icons[segment.index]
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: control.icons[segment.index] || ""
                            font.family: ui.iconFont
                            font.pixelSize: 15
                            color: segment.selected ? ui.label : ui.secondaryLabel
                        }
                        Text {
                            visible: !control.iconOnly
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: segment.text
                            font.family: ui.font
                            font.pixelSize: ui.callout
                            font.weight: segment.selected ? Font.DemiBold : Font.Medium
                            color: segment.selected ? ui.label : ui.secondaryLabel
                        }
                    }
                }
                onClicked: {
                    if (control.autoSelect) control.currentIndex = index
                    control.activated(index)
                }
                PointerArea {}
            }
        }
    }
}
