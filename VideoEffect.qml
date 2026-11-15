import QtQuick
import qs.Commons
import qs.Commons as Commons

// Capture only the video. Labels and buttons stay outside this effect.
Loader {
    id: root
    property Item sourceItem: null
    property string style: "original"
    property real strength: 0.35
    property int pixelSize: 3
    readonly property bool pixelated: style === "pixel" || style === "theme-pixel"
    readonly property bool tinted: style === "theme" || style === "theme-pixel"
    readonly property bool failed: item ? item.failed : false
    // Original and stopped playback allocate no effect texture.
    sourceComponent: style !== "original" ? effectComponent : null

    Component {
        id: effectComponent
        Item {
            readonly property bool failed: shader.status === ShaderEffect.Error
            ShaderEffectSource {
                id: capture
                sourceItem: parent.failed ? null : root.sourceItem
                hideSource: !parent.failed
                visible: false
                live: true
                textureSize: Qt.size(Math.max(1, Math.ceil(root.width / (root.pixelated ? root.pixelSize : 1))),
                                     Math.max(1, Math.ceil(root.height / (root.pixelated ? root.pixelSize : 1))))
                smooth: !root.pixelated
            }
            ShaderEffect {
                id: shader
                anchors.fill: parent
                visible: !parent.failed
                property variant source: capture
                property color shadowColor: Commons.Color.background
                property color lightColor: Commons.Color.foreground
                property color accentColor: Commons.Color.accent
                property real tintAmount: root.tinted ? root.strength : 0
                fragmentShader: Qt.resolvedUrl("shaders/video.frag.qsb")
            }
        }
    }
}
