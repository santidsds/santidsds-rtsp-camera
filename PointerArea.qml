import QtQuick

// Non-interactive hover layer that only sets a pointer cursor.
// acceptedButtons: NoButton lets clicks fall through to the control beneath.
MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
    cursorShape: Qt.PointingHandCursor
    z: 100
}
