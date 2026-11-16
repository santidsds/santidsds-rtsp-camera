import QtQuick
import QtQuick.Controls
import QtQuick.Controls as Controls
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Motion events from the last 24 hours (stills saved by motiond.py), grouped by
// hour, with bursts from one camera collapsed into a single tile. A still opens
// in a viewer whose main action jumps to that moment in Recordings.
FocusScope {
    id: root
    Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
    AppleStyle { id: ui }

    // Index into visibleItems of the still open in the viewer, or -1 for the grid.
    property int selectedIndex: -1
    readonly property url selectedSource: selectedIndex >= 0 && selectedIndex < visibleItems.length
        ? "file://" + visibleItems[selectedIndex].path : ""
    // Camera filter ("" = every camera), driven by the toolbar's camera menu.
    property string cameraFilter: ""
    // Time filter: everything, the last hour, today, or last night (22:00-07:00).
    property string timeFilter: "all"
    readonly property var timeFilterKeys: ["all", "hour", "today", "night"]
    readonly property var cameraOptions: {
        var seen = {}, options = []
        for (var i = 0; i < items.length; i++) {
            var id = items[i].cameraId || ""
            if (seen[id]) continue
            seen[id] = true
            options.push({id: id, name: cameraLabel(items[i])})
        }
        options.sort(function(a, b) { return a.name.localeCompare(b.name) })
        return options
    }
    readonly property string activeFilter: cameraFilter
    readonly property var visibleItems: items.filter(function(item) {
        return (activeFilter === "" || (item.cameraId || "") === activeFilter) && inTimeFilter(item)
    })
    readonly property bool showCameraNames: cameraOptions.length > 1 && activeFilter === ""
    onActiveFilterChanged: selectedIndex = -1
    onTimeFilterChanged: selectedIndex = -1
    property string listenerState: ""
    property string listenerDetails: ""
    property string today: Qt.formatDate(new Date(), "yyyy-MM-dd")  // refreshed with the list
    signal closed()
    signal openInRecordings(string cameraId, string date, string time)

    // Bursts: stills from one camera less than a minute apart are one event, even when
    // another camera's stills come in between. `members` are indexes into visibleItems,
    // newest first; a group is listed at its newest still.
    readonly property var groups: {
        var result = [], open = {}
        for (var i = 0; i < visibleItems.length; i++) {
            var item = visibleItems[i], at = stamp(item), camera = item.cameraId || "", last = open[camera]
            if (last && last.date === item.date && !isNaN(at) && !isNaN(last.lastStamp)
                    && Math.abs(last.lastStamp - at) <= 60000) {
                last.members.push(i)
                last.count++
                last.lastStamp = at
                continue
            }
            var group = {first: i, members: [i], count: 1, cameraId: camera, date: item.date, lastStamp: at,
                section: isNaN(at) ? "" : Qt.formatDateTime(new Date(at), "yyyy-MM-dd HH")}
            open[camera] = group
            result.push(group)
        }
        return result
    }
    readonly property int selectedGroup: {
        for (var g = 0; g < groups.length; g++)
            if (groups[g].members.indexOf(selectedIndex) >= 0) return g
        return -1
    }
    property int columns: Math.max(2, Math.floor((width - 8) / 190))
    // Rows for the list: a header per hour, then rows of tiles.
    readonly property var rows: {
        var out = [], i = 0
        while (i < groups.length) {
            var section = groups[i].section, inSection = []
            while (i < groups.length && groups[i].section === section) inSection.push(groups[i++])
            out.push({type: "header", section: section, label: sectionLabel(section, inSection.length)})
            for (var j = 0; j < inSection.length; j += columns)
                out.push({type: "tiles", section: section, groups: inSection.slice(j, j + columns)})
        }
        return out
    }

    function stamp(item) {
        if (typeof item.mtime === "number") return item.mtime * 1000
        var parsed = Date.parse(String(item.date || "") + "T" + String(item.time || ""))
        return isNaN(parsed) ? NaN : parsed
    }
    function inTimeFilter(item) {
        if (timeFilter === "all") return true
        var at = stamp(item)
        if (isNaN(at)) return false
        var now = new Date()
        if (timeFilter === "hour") return Date.now() - at <= 3600000
        if (timeFilter === "today") return item.date === Qt.formatDate(now, "yyyy-MM-dd")
        // Last night: 22:00-07:00 (still running if it's night now).
        var start = new Date(now), end = new Date(now)
        if (now.getHours() >= 22) { start.setHours(22, 0, 0, 0) }
        else { start.setDate(start.getDate() - 1); start.setHours(22, 0, 0, 0); if (now.getHours() >= 7) end.setHours(7, 0, 0, 0) }
        return at >= start.getTime() && at <= end.getTime()
    }
    function sectionLabel(section, count) {
        var events = strings.tn("motion.events", count).arg(Commons.I18n.formatNumber(count))
        if (!section) return events
        var date = section.slice(0, 10), hour = section.slice(11, 13) + ":00"
        return (date !== today ? dayLabel({date: date}) + " · " : "") + hour + " · " + events
    }
    // The viewer steps event by event (a burst is one step).
    function step(delta) {
        if (selectedIndex < 0 || groups.length === 0) return
        var next = Math.max(0, Math.min(groups.length - 1, selectedGroup + delta))
        selectedIndex = groups[next].first
    }
    function cameraLabel(item) {
        return String(item.cameraName || "").slice(0, 64) || strings.t("motion.unknownCamera")
    }
    // Reduce daemon status (per-camera or the older flat format) to a chip.
    function summarizeStatus(s) {
        if (s.enabled === false) return {state: "disabled", line: strings.t("motion.disabled"), details: ""}
        var cameras = s.cameras && typeof s.cameras === "object" ? s.cameras : null
        if (!cameras) {
            if (s.listening === false && s.lastError)
                return {state: "offline", line: strings.t("motion.listenerOffline").arg(String(s.lastError).slice(0, 120)), details: ""}
            if (s.listening === true)
                return {state: "on", line: s.camera ? strings.t("motion.listeningTo").arg(String(s.camera).slice(0, 64))
                    : strings.t("motion.listening"), details: ""}
            return {state: "starting", line: strings.t("motion.starting"), details: ""}
        }
        var entries = Object.keys(cameras).map(function(id) { return cameras[id] || {} })
        if (entries.length === 0) return {state: "starting", line: strings.t("motion.starting"), details: ""}
        var listening = entries.filter(function(c) { return c.listening === true })
        var failing = entries.filter(function(c) { return c.listening !== true && (c.lastError || c.source === "none") })
        var details = entries.map(function(c) {
            var name = String(c.name || "").slice(0, 64) || strings.t("motion.unknownCamera")
            if (c.listening === true) return strings.t("motion.cameraListening").arg(name)
            if (c.source === "none") return strings.t("motion.cameraNoSource").arg(name)
            if (c.lastError) return strings.t("motion.cameraOffline").arg(name).arg(String(c.lastError).slice(0, 80))
            return strings.t("motion.cameraStarting").arg(name)
        }).join("\n")
        if (failing.length > 0) {
            var first = String(failing[0].name || "").slice(0, 64) || strings.t("motion.unknownCamera")
            return {state: listening.length > 0 ? "partial" : "offline",
                line: strings.t("motion.cameraDown").arg(first), details: details}
        }
        if (listening.length === entries.length)
            return {state: "on", line: entries.length === 1
                ? strings.t("motion.listeningTo").arg(String(entries[0].name || "").slice(0, 64))
                : strings.tn("motion.listeningCount", entries.length).arg(Commons.I18n.formatNumber(entries.length)),
                details: details}
        return {state: "starting", line: strings.t("motion.starting"), details: details}
    }
    function dayLabel(item) {
        if (!item.date || item.date === today) return strings.t("motion.today")
        var date = new Date(item.date + "T12:00:00")
        var yesterday = new Date(); yesterday.setDate(yesterday.getDate() - 1)
        if (Qt.formatDate(yesterday, "yyyy-MM-dd") === item.date) return strings.t("motion.yesterday")
        return date.toLocaleDateString(Qt.locale(Commons.I18n.formatLocale), "d MMM")
    }

    readonly property string helper: Qt.resolvedUrl("motiond.py").toString().replace(/^file:\/\//, "")
    readonly property color foreground: Commons.Color.foreground
    property var items: []
    property bool loading: false
    property string listError: ""
    property string statusLine: ""

    // Cameras on DVRIP (XMeye/iCSee) have recordings on their SD card.
    property string clipHelper: Qt.resolvedUrl("sdclip.py").toString().replace(/^file:\/\//, "")
    property var clipSources: ({})
    readonly property var previewItem: selectedIndex >= 0 && selectedIndex < visibleItems.length
        ? visibleItems[selectedIndex] : null
    readonly property bool clipAvailable: previewItem !== null
        && clipSources[previewItem.cameraId || ""] === "dvrip"
        && /^\d{4}-\d{2}-\d{2}$/.test(String(previewItem.date || ""))
        && /^\d{2}:\d{2}:\d{2}$/.test(String(previewItem.time || ""))
    // "Save clip": download the moment from the SD card, then copy it to Videos.
    property string saveState: ""   // "", "fetching", "saving", "saved", "error"
    property string saveError: ""
    property real saveProgress: 0
    property string saveFor: ""      // the still the save belongs to
    property bool savePending: false // waits for a cancelled download to finish stopping
    readonly property bool saveRetryable: saveError !== "login" && saveError !== "unsupported"
    onSelectedIndexChanged: cancelSave()

    function openPreviewInRecordings() {
        if (!clipAvailable) return
        // A burst starts at its oldest still.
        var group = selectedGroup >= 0 ? groups[selectedGroup] : null
        var item = group ? visibleItems[group.members[group.members.length - 1]] : previewItem
        selectedIndex = -1
        openInRecordings(String(item.cameraId), item.date, item.time)
    }
    function clipErrorText(code) {
        var keys = {"no-recording": "clip.error.noRecording", "login": "clip.error.login",
            "unreachable": "clip.error.unreachable", "timeout": "clip.error.timeout", "busy": "clip.error.busy",
            "empty": "clip.error.empty", "unsupported": "clip.error.unsupported"}
        return strings.t(keys[code] || "clip.error.failed")
    }
    function megabytes(bytes) {
        return strings.t("clip.megabytes").arg(Qt.locale(Commons.I18n.formatLocale).toString(bytes / 1048576, "f", 1))
    }
    function startSave() {
        if (!clipAvailable || clipSaver.running) return
        saveFor = previewItem.path
        saveState = "fetching"; saveError = ""; saveProgress = 0
        if (clipFetcher.running) { savePending = true; return }
        clipFetcher.gotResult = false
        clipFetcher.command = ["python3", clipHelper, "--camera", String(previewItem.cameraId),
            "--at", previewItem.date + " " + previewItem.time]
        clipFetcher.running = true
    }
    // Leaving a still cancels its download (sdclip.py then tells the camera to stop).
    function cancelSave() {
        savePending = false
        if (clipFetcher.running) clipFetcher.running = false
        saveState = ""; saveError = ""; saveProgress = 0; saveFor = ""
    }
    function handleFetchLine(line) {
        var message
        try { message = JSON.parse(line) } catch (error) { return }
        if (!message || typeof message !== "object" || saveState !== "fetching" || savePending) return
        if (typeof message.progress === "number") { saveProgress = message.progress; return }
        clipFetcher.gotResult = true
        if (message.ok === true && typeof message.path === "string" && message.path !== "" && previewItem) {
            saveState = "saving"
            clipSaver.command = ["python3", clipHelper, "--camera", String(previewItem.cameraId), "--save", message.path]
            clipSaver.running = true
        } else {
            saveError = String(message.error || "failed")
            saveState = "error"
        }
    }

    function refresh() {
        today = Qt.formatDate(new Date(), "yyyy-MM-dd")
        if (lister.running) return
        loading = true
        listError = ""
        lister.running = true
    }

    // Esc closes the viewer; otherwise the panel handles it (leave full screen, then the tab).
    Keys.onEscapePressed: function(event) {
        event.accepted = selectedIndex >= 0
        selectedIndex = -1
    }
    Keys.onLeftPressed: function(event) { event.accepted = selectedIndex >= 0; step(-1) }
    Keys.onRightPressed: function(event) { event.accepted = selectedIndex >= 0; step(1) }
    Keys.onSpacePressed: function(event) { event.accepted = selectedIndex >= 0 && clipAvailable; openPreviewInRecordings() }
    Keys.onReturnPressed: function(event) { event.accepted = selectedIndex >= 0 && clipAvailable; openPreviewInRecordings() }

    Component.onCompleted: refresh()

    Process {
        id: lister
        property string lastListing: ""
        command: ["python3", root.helper, "--list"]
        stdout: StdioCollector { id: listStdout }
        stderr: StdioCollector { id: listStderr }
        onExited: function(code) {
            root.loading = false
            if (code !== 0) {
                root.listError = strings.t("motion.listError")
                root.items = []
                return
            }
            if (listStdout.text === lastListing && root.items.length) return  // unchanged: keep the scroll
            try {
                var parsed = JSON.parse(listStdout.text || "[]")
                if (!Array.isArray(parsed)) throw new Error()
                lastListing = listStdout.text
                root.items = parsed
            } catch (error) {
                root.listError = strings.t("motion.listUnreadable")
                root.items = []
            }
        }
    }

    // The daemon reports status (one source of truth for its data directory).
    Process {
        id: statusReader
        command: ["python3", root.helper, "--status"]
        stdout: StdioCollector { id: statusStdout }
        onExited: function(code) {
            if (code !== 0) {
                root.listenerState = "unknown"
                root.statusLine = strings.t("motion.statusUnavailable")
                root.listenerDetails = ""
                return
            }
            try {
                var status = JSON.parse(statusStdout.text || "{}")
                var sources = {}
                if (status.cameras && typeof status.cameras === "object")
                    for (var id in status.cameras) sources[id] = String((status.cameras[id] || {}).source || "")
                root.clipSources = sources
                var summary = root.summarizeStatus(status)
                root.listenerState = summary.state
                root.statusLine = summary.line
                root.listenerDetails = summary.details
            } catch (error) {
                root.listenerState = ""
                root.statusLine = ""
                root.listenerDetails = ""
            }
        }
    }
    Process {
        id: clipFetcher
        property bool gotResult: false
        stdout: SplitParser { onRead: function(line) { root.handleFetchLine(line) } }
        onExited: function(code) {
            if (root.savePending) {
                root.savePending = false
                // Restart after this handler: the process may still count as running here.
                if (root.saveState === "fetching" && root.previewItem && root.previewItem.path === root.saveFor)
                    Qt.callLater(root.startSave)
                return
            }
            if (root.saveState === "fetching" && !gotResult) {
                root.saveError = "failed"
                root.saveState = "error"
            }
        }
    }
    Process {
        id: clipSaver
        stdout: StdioCollector { id: saveStdout }
        onExited: function(code) {
            if (root.saveState !== "saving" || !root.previewItem || root.previewItem.path !== root.saveFor) return
            try {
                var lines = saveStdout.text.trim().split("\n")
                root.saveState = JSON.parse(lines[lines.length - 1]).ok === true ? "saved" : "error"
            } catch (error) {
                root.saveState = "error"
            }
            if (root.saveState === "error" && !root.saveError) root.saveError = "failed"
        }
    }

    Timer {
        interval: 15000
        running: root.visible && root.selectedIndex < 0
        repeat: true
        onTriggered: {
            root.refresh()
            statusReader.running = false
            statusReader.running = true
        }
    }

    onVisibleChanged: {
        if (!root.visible) { root.cancelSave(); return }
        root.refresh()
        statusReader.running = false
        statusReader.running = true
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 2
            spacing: 10
            MacSegmented {
                id: timeFilterControl
                objectName: "motionTimeFilter"
                model: [strings.t("motion.anyTime"), strings.t("motion.lastHour"), strings.t("motion.today"), strings.t("motion.lastNight")]
                segmentNames: ["filterAll", "filterHour", "filterToday", "filterNight"]
                autoSelect: false
                currentIndex: root.timeFilterKeys.indexOf(root.timeFilter)
                onActivated: function(index) { root.timeFilter = root.timeFilterKeys[index] }
            }
            MacText {
                objectName: "motionSubtitle"
                visible: root.width >= 560
                text: strings.tn("motion.events", root.groups.length).arg(Commons.I18n.formatNumber(root.groups.length))
                color: ui.secondaryLabel
                font.pixelSize: ui.callout
                font.features: { "tnum": 1 }
            }
            Item { Layout.fillWidth: true }
            Rectangle {
                objectName: "listenerChip"
                visible: root.statusLine !== ""
                Layout.maximumWidth: Math.max(120, root.width * 0.38)
                implicitWidth: chipRow.implicitWidth + 22
                implicitHeight: 26
                radius: height / 2
                color: ui.fill
                HoverHandler { id: chipHover }
                PanelToolTip {
                    visible: chipHover.hovered && root.listenerDetails !== ""
                    text: root.listenerDetails
                    fontSize: Style.font.caption
                }
                RowLayout {
                    id: chipRow
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 12
                    spacing: 7
                    StatusDot {
                        tone: root.listenerState === "on" ? ui.systemGreen
                            : root.listenerState === "offline" ? ui.systemRed
                            : root.listenerState === "starting" || root.listenerState === "partial" ? ui.systemOrange
                            : ui.tertiaryLabel
                        pulsing: root.listenerState === "starting"
                    }
                    MacText {
                        Layout.fillWidth: true
                        text: root.statusLine
                        color: ui.secondaryLabel
                        font.pixelSize: ui.caption
                        font.weight: Font.Medium
                    }
                }
            }
            MacToolbarButton {
                id: refreshButton
                objectName: "motionRefresh"
                glyph: ui.iconRefresh
                tipText: strings.t("motion.refresh")
                enabled: !root.loading
                onClicked: root.refresh()
            }
        }

        MacText {
            Layout.fillWidth: true
            visible: root.listError !== ""
            text: root.listError
            color: ui.systemRed
            font.pixelSize: ui.callout
            wrapMode: Text.WordWrap
        }

        // Empty state, in the style of a content-unavailable view.
        ColumnLayout {
            objectName: "motionEmpty"
            visible: !root.loading && !root.listError && root.visibleItems.length === 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 6
            Item { Layout.fillHeight: true }
            Text {
                Layout.alignment: Qt.AlignHCenter
                textFormat: Text.PlainText
                text: ui.iconMotion
                font.family: ui.iconFont
                font.pixelSize: 44
                color: ui.tertiaryLabel
            }
            MacText {
                Layout.alignment: Qt.AlignHCenter
                text: root.items.length ? strings.t("motion.emptyFiltered") : strings.t("motion.emptyTitle")
                font.pixelSize: ui.headline
                font.weight: Font.DemiBold
            }
            MacText {
                Layout.alignment: Qt.AlignHCenter
                Layout.maximumWidth: Math.min(360, root.width - 32)
                visible: root.items.length === 0
                text: strings.t("motion.emptyBody")
                color: ui.secondaryLabel
                font.pixelSize: ui.callout
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideNone
            }
            Item { Layout.fillHeight: true }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.visibleItems.length > 0
            ListView {
                id: grid
                objectName: "motionGrid"
                anchors.fill: parent
                model: root.rows
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                cacheBuffer: 600
                readonly property real cellWidth: Math.floor(width / root.columns)
                readonly property real cellHeight: Math.round(cellWidth * 0.62)
                Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
                // The hour the top of the list is in, shown pinned over the list.
                readonly property string topLabel: {
                    var row = indexAt(10, contentY + 2)
                    if (row < 0 || contentY <= 2) return ""
                    var section = root.rows[row] ? root.rows[row].section : null
                    for (var i = row; i >= 0; i--)
                        if (root.rows[i].type === "header" && root.rows[i].section === section) return root.rows[i].label
                    return ""
                }
                delegate: Item {
                    id: rowItem
                    required property var modelData
                    width: grid.width
                    height: modelData.type === "header" ? 30 : grid.cellHeight
                    MacText {
                        objectName: "motionSectionHeader"
                        visible: rowItem.modelData.type === "header"
                        anchors.left: parent.left
                        anchors.leftMargin: 4
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 6
                        text: rowItem.modelData.label || ""
                        color: ui.secondaryLabel
                        font.pixelSize: ui.callout
                        font.weight: Font.DemiBold
                        font.features: { "tnum": 1 }
                    }
                    Row {
                        visible: rowItem.modelData.type === "tiles"
                        Repeater {
                            model: rowItem.modelData.type === "tiles" ? rowItem.modelData.groups : []
                            Tile {
                                required property var modelData
                                group: modelData
                                width: grid.cellWidth
                                height: grid.cellHeight
                            }
                        }
                    }
                }
            }
            Rectangle {  // pinned hour header
                objectName: "motionStickyHeader"
                visible: grid.topLabel !== ""
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 30
                color: Commons.Color.popups.background
                MacText {
                    anchors.left: parent.left
                    anchors.leftMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    text: grid.topLabel
                    color: ui.secondaryLabel
                    font.pixelSize: ui.callout
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                }
            }
            Rectangle {  // the list continues below
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 28
                visible: grid.contentY + grid.height < grid.contentHeight - 2
                gradient: Gradient {
                    GradientStop { position: 0; color: "transparent" }
                    GradientStop { position: 1; color: Commons.Color.popups.background }
                }
            }
        }
    }

    // Full-size viewer with previous/next navigation (also ←/→ and Esc).
    Rectangle {
        id: preview
        objectName: "motionPreview"
        visible: root.selectedIndex >= 0
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.9)
        radius: 12
        z: 10
        readonly property var item: root.previewItem
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }

        MouseArea {
            anchors.fill: parent
            onClicked: root.selectedIndex = -1
        }
        Image {
            id: stillImage
            anchors.fill: parent
            anchors.leftMargin: 56
            anchors.rightMargin: 56
            anchors.topMargin: 48
            anchors.bottomMargin: 64
            source: root.selectedSource
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: false
            MouseArea {  // clicking the still opens its moment in Recordings
                anchors.centerIn: parent
                width: stillImage.paintedWidth
                height: stillImage.paintedHeight
                cursorShape: root.clipAvailable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.clipAvailable ? root.openPreviewInRecordings() : (root.selectedIndex = -1)
            }
        }
        MacText {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 16
            width: Math.min(implicitWidth, parent.width - 120)
            text: preview.item ? root.cameraLabel(preview.item) + " · " + root.dayLabel(preview.item) + " · "
                + (preview.item.time || preview.item.name) + "    " + (root.selectedGroup + 1) + " / " + root.groups.length : ""
            color: "white"
            font.pixelSize: ui.callout
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
        }

        // Actions: watch this moment in Recordings, or keep a copy of the clip.
        Rectangle {
            id: actionBar
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 14
            width: Math.min(parent.width - 32, actionRow.implicitWidth + 16)
            height: 40
            radius: height / 2
            visible: root.clipAvailable
            color: root.saveState === "" ? "transparent" : Qt.rgba(0.12, 0.12, 0.13, 0.82)
            MouseArea { anchors.fill: parent }  // keep clicks from closing the viewer
            RowLayout {
                id: actionRow
                anchors.centerIn: parent
                spacing: 8
                GlassPill {
                    objectName: "openInRecordings"
                    glyph: ui.iconPlay
                    text: strings.t("motion.openInRecordings")
                    primary: true
                    onClicked: root.openPreviewInRecordings()
                }
                GlassPill {
                    objectName: "saveClip"
                    visible: root.saveState === ""
                    glyph: ui.iconDownload
                    text: strings.t("motion.saveClip")
                    onClicked: root.startSave()
                }
                Text {
                    visible: root.saveState === "fetching" || root.saveState === "saving"
                    textFormat: Text.PlainText
                    text: ui.iconLoading
                    font.family: ui.iconFont
                    font.pixelSize: 15
                    color: "white"
                    RotationAnimator on rotation {
                        from: 0; to: 360; duration: 1000; loops: Animation.Infinite
                        running: (root.saveState === "fetching" || root.saveState === "saving") && root.visible
                    }
                }
                MacText {
                    objectName: "saveClipStatus"
                    visible: root.saveState !== ""
                    text: root.saveState === "fetching" ? strings.t("motion.savingClip")
                            + (root.saveProgress > 0 ? "  " + root.megabytes(root.saveProgress) : "")
                        : root.saveState === "saving" ? strings.t("motion.savingClip")
                        : root.saveState === "saved" ? strings.t("clip.saved")
                        : root.clipErrorText(root.saveError)
                    color: "white"
                    font.pixelSize: ui.callout
                    font.features: { "tnum": 1 }
                }
                GlassPill {
                    objectName: "saveClipCancel"
                    visible: root.saveState === "fetching"
                    text: strings.t("clip.cancel")
                    onClicked: root.cancelSave()
                }
                GlassPill {
                    objectName: "saveClipRetry"
                    visible: root.saveState === "error" && root.saveRetryable
                    text: strings.t("clip.retry")
                    onClicked: root.startSave()
                }
            }
        }
        GlassButton {
            objectName: "motionPreviewClose"
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: 10
            text: ui.iconClose
            tipText: strings.t("motion.closePreview")
            onClicked: root.selectedIndex = -1
        }
        GlassButton {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: ui.iconChevronLeft
            tipText: strings.t("motion.newer")
            enabled: root.selectedGroup > 0
            onClicked: root.step(-1)
        }
        GlassButton {
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: ui.iconChevronRight
            tipText: strings.t("motion.older")
            enabled: root.selectedGroup < root.groups.length - 1
            onClicked: root.step(1)
        }
    }

    // One event: its newest still, its time, its camera, and ×N for a burst.
    component Tile: Item {
        id: tile
        property var group: ({first: 0, count: 1})
        readonly property var still: root.visibleItems[group.first] || ({})
        Item {
            id: thumb
            anchors.fill: parent
            anchors.margins: 4
            layer.enabled: true
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: thumbMask
                maskThresholdMin: 0.5
                maskSpreadAtMin: 1.0
            }
            Rectangle { anchors.fill: parent; color: "#0e0e10" }
            Image {
                anchors.fill: parent
                source: tile.still.path ? "file://" + tile.still.path : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: false
                sourceSize.width: 380
                sourceSize.height: 240
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Math.min(parent.height * 0.5, 44)
                gradient: Gradient {
                    GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0) }
                    GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.62) }
                }
            }
            Text {
                objectName: "stillCameraName"
                visible: root.showCameraNames
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.rightMargin: 8
                anchors.bottomMargin: 6
                width: Math.min(implicitWidth, parent.width * 0.45)
                textFormat: Text.PlainText
                text: root.cameraLabel(tile.still)
                font.family: ui.font
                font.pixelSize: ui.caption
                font.weight: Font.Medium
                color: Qt.rgba(1, 1, 1, 0.8)
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignRight
            }
            Text {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.leftMargin: 8
                anchors.bottomMargin: 6
                width: parent.width * (root.showCameraNames ? 0.5 : 1) - 16
                textFormat: Text.PlainText
                text: (tile.still.date && tile.still.date !== root.today
                    ? root.dayLabel(tile.still) + " · " : "") + (tile.still.time || tile.still.name || "")
                font.family: ui.font
                font.pixelSize: ui.caption
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                color: "white"
                elide: Text.ElideRight
            }
            Rectangle {
                objectName: "burstBadge"
                visible: tile.group.count > 1
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 6
                width: badgeText.implicitWidth + 12
                height: 20
                radius: height / 2
                color: Qt.rgba(0, 0, 0, 0.6)
                Text {
                    id: badgeText
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: "×" + tile.group.count
                    font.family: ui.font
                    font.pixelSize: ui.caption
                    font.weight: Font.DemiBold
                    color: "white"
                }
            }
            Rectangle {
                anchors.fill: parent
                color: "white"
                opacity: tileMouse.containsMouse ? 0.08 : 0
                Behavior on opacity { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
            }
        }
        Item {
            id: thumbMask
            anchors.fill: thumb
            visible: false
            layer.enabled: true
            Rectangle { anchors.fill: parent; radius: 10 }
        }
        MouseArea {
            id: tileMouse
            anchors.fill: thumb
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                root.selectedIndex = tile.group.first
                root.forceActiveFocus()
            }
        }
    }

    // Text (optionally with an icon) on a translucent capsule, for the dark viewer.
    component GlassPill: Controls.Button {
        id: glassPill
        property string glyph: ""
        property bool primary: false
        implicitHeight: 30
        leftPadding: 14
        rightPadding: 14
        hoverEnabled: true
        focusPolicy: Qt.TabFocus
        Accessible.name: text
        opacity: enabled ? 1 : 0.4
        contentItem: Row {
            spacing: 7
            Text {
                visible: glassPill.glyph !== ""
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: glassPill.glyph
                font.family: ui.iconFont
                font.pixelSize: 15
                color: glassPill.primary ? "#1c1c1e" : "white"
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: glassPill.text
                font.family: ui.font
                font.pixelSize: ui.callout
                font.weight: Font.DemiBold
                color: glassPill.primary ? "#1c1c1e" : "white"
            }
        }
        background: Rectangle {
            radius: height / 2
            color: glassPill.primary ? (glassPill.down ? Qt.rgba(1, 1, 1, 0.75) : glassPill.hovered ? Qt.rgba(1, 1, 1, 0.95) : Qt.rgba(1, 1, 1, 0.88))
                : glassPill.down ? Qt.rgba(1, 1, 1, 0.3) : glassPill.hovered ? Qt.rgba(1, 1, 1, 0.24) : Qt.rgba(1, 1, 1, 0.16)
            border.width: glassPill.visualFocus ? 2 : 0
            border.color: ui.alpha(ui.accent, 0.9)
        }
        PointerArea { visible: glassPill.enabled }
    }

    component GlassButton: Controls.Button {
        id: glassButton
        property string tipText: ""
        implicitWidth: 32
        implicitHeight: 32
        padding: 0
        hoverEnabled: true
        focusPolicy: Qt.TabFocus
        Accessible.name: tipText
        opacity: enabled ? 1 : 0.35
        PanelToolTip {
            visible: glassButton.hovered && glassButton.tipText !== ""
            text: glassButton.tipText
            fontSize: Style.font.caption
        }
        contentItem: Text {
            textFormat: Text.PlainText
            text: glassButton.text
            font.family: ui.iconFont
            font.pixelSize: 17
            color: "white"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: width / 2
            color: glassButton.hovered ? Qt.rgba(1, 1, 1, 0.22) : Qt.rgba(1, 1, 1, 0.12)
            border.width: glassButton.visualFocus ? 2 : 1
            border.color: glassButton.visualFocus ? ui.alpha(ui.accent, 0.9) : Qt.rgba(1, 1, 1, 0.14)
        }
        PointerArea { visible: glassButton.enabled }
    }
}
