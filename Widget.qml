import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

BarWidget {
    id: root
    moduleName: "yani.camera"
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight
    readonly property bool opened: panel.opened
    readonly property bool popoutSwitchClosing: panel.popoutSwitchClosing
    function open() { panel.open() }
    function close() { panel.close() }
    function togglePanel() { panel.toggle() }
    function closeForPopoutSwitch() { if (!panel.pinned) panel.closeForPopoutSwitch() }

    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "\udb81\udfae" // Material Design CCTV (U+F07AE).
        fontFamily: "JetBrainsMono Nerd Font"
        tooltipText: "Camera"
        onPressed: root.togglePanel()
    }
    CameraPanel {
        id: panel
        bar: root.bar
        anchorItem: button
        hostWidget: root
    }
    IpcHandler {
        target: "yani.camera"
        function open(): void { root.open() }
        function close(): void { root.close() }
        function toggle(): void { root.togglePanel() }
        function status(): string { return panel.playbackStatus() }
        function toggleDualView(): void { panel.toggleDualView() }
        function toggleAudio(): void { panel.toggleAudio() }
        function resize(width: int, height: int): void { panel.resizeViewer(width, height) }
        function togglePin(): void { panel.pinned = !panel.pinned }
    }
}
