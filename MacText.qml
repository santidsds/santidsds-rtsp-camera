import QtQuick

// Plain-text label in the system UI font. Never interprets markup.
Text {
    AppleStyle { id: ui }
    textFormat: Text.PlainText
    font.family: ui.font
    font.pixelSize: ui.body
    color: ui.label
    elide: Text.ElideRight
    verticalAlignment: Text.AlignVCenter
}
