import QtQuick
import qs.Commons
import qs.Commons as Commons

// macOS-style design tokens shared by the camera views. Colors derive from the
// Omarchy palette so the accent follows the theme (Graphite on grey themes);
// only status colors use Apple's fixed system values.
QtObject {
    id: ui

    readonly property string font: {
        var families = Qt.fontFamilies()
        var preferred = ["SF Pro Text", "SF Pro Display", "SF Pro", "Inter Variable", "Inter"]
        for (var i = 0; i < preferred.length; i++) {
            if (families.indexOf(preferred[i]) >= 0) return preferred[i]
        }
        return Style.font.family
    }
    readonly property string iconFont: "JetBrainsMono Nerd Font"

    // Type scale (px), close to macOS: headline 15, body 13, callout 12, caption 11.
    readonly property int largeTitle: 17
    readonly property int headline: 15
    readonly property int body: 13
    readonly property int callout: 12
    readonly property int caption: 11

    readonly property color label: Commons.Color.popups.text
    readonly property color secondaryLabel: alpha(label, 0.62)
    readonly property color tertiaryLabel: alpha(label, 0.38)
    readonly property color separator: alpha(label, 0.10)
    readonly property color fill: alpha(label, 0.08)
    readonly property color fillHover: alpha(label, 0.13)
    readonly property color fillPressed: alpha(label, 0.19)
    readonly property color groupFill: alpha(label, 0.05)
    readonly property color groupBorder: alpha(label, 0.08)
    readonly property color accent: Commons.Color.accent
    readonly property color onAccent: luminance(accent) > 0.55 ? "#000000" : "#ffffff"
    readonly property color menuBackground: Qt.rgba(Commons.Color.background.r, Commons.Color.background.g,
        Commons.Color.background.b, 0.97)
    readonly property color glass: Qt.rgba(0, 0, 0, 0.42)
    readonly property color glassHover: Qt.rgba(0, 0, 0, 0.58)
    readonly property color glassBorder: Qt.rgba(1, 1, 1, 0.16)

    readonly property color systemGreen: "#30d158"
    readonly property color systemOrange: "#ff9f0a"
    readonly property color systemRed: "#ff453a"

    readonly property int controlRadius: 7
    readonly property int groupRadius: 10
    readonly property int videoRadius: 12
    readonly property int controlHeight: 28

    readonly property string iconVolume: String.fromCodePoint(0xF057E)
    readonly property string iconVolumeOff: String.fromCodePoint(0xF0581)
    readonly property string iconFullscreen: String.fromCodePoint(0xF0293)
    readonly property string iconFullscreenExit: String.fromCodePoint(0xF0294)
    readonly property string iconSplit: String.fromCodePoint(0xF0BCC)
    readonly property string iconPalette: String.fromCodePoint(0xF03D8)
    readonly property string iconSettings: String.fromCodePoint(0xF0493)
    readonly property string iconPin: String.fromCodePoint(0xF0403)
    readonly property string iconPinOutline: String.fromCodePoint(0xF0931)
    readonly property string iconClose: String.fromCodePoint(0xF0156)
    readonly property string iconRefresh: String.fromCodePoint(0xF0450)
    readonly property string iconChevronDown: String.fromCodePoint(0xF0140)
    readonly property string iconChevronLeft: String.fromCodePoint(0xF0141)
    readonly property string iconChevronRight: String.fromCodePoint(0xF0142)
    readonly property string iconPlus: String.fromCodePoint(0xF0415)
    readonly property string iconCheck: String.fromCodePoint(0xF012C)
    readonly property string iconMotion: String.fromCodePoint(0xF0D91)
    readonly property string iconLive: String.fromCodePoint(0xF0567)
    readonly property string iconLock: String.fromCodePoint(0xF033E)
    readonly property string iconLoading: String.fromCodePoint(0xF0772)
    readonly property string iconCamera: String.fromCodePoint(0xF07AE)
    readonly property string iconPlay: String.fromCodePoint(0xF040A)
    readonly property string iconPause: String.fromCodePoint(0xF03E4)
    readonly property string iconReplay: String.fromCodePoint(0xF0459)
    readonly property string iconDownload: String.fromCodePoint(0xF01DA)
    readonly property string iconImage: String.fromCodePoint(0xF02E9)
    readonly property string iconHistory: String.fromCodePoint(0xF02DA)
    readonly property string iconSkipPrevious: String.fromCodePoint(0xF04AE)
    readonly property string iconSkipNext: String.fromCodePoint(0xF04AD)
    readonly property string iconBack: String.fromCodePoint(0xF013D)
    readonly property string iconForward: String.fromCodePoint(0xF013E)

    function alpha(color, amount) { return Qt.rgba(color.r, color.g, color.b, amount) }
    function luminance(color) { return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b }
}
