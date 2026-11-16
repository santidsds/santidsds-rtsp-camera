import QtQuick
import QtQuick.Controls
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
    id: root
    moduleName: "yani.camera"
    manageIpc: false
    Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
    AppleStyle { id: ui }
    property var anchorItem: null
    property var hostWidget: null
    property bool configuring: true
    property bool showingMotion: false
    property bool showingRecordings: false
    // Motion and Recordings replace the live view (its streams stop meanwhile).
    readonly property bool browsing: showingMotion || showingRecordings
    // Motion's camera filter ("" = all cameras), chosen in the toolbar's camera menu.
    property string motionCameraFilter: ""
    readonly property string activeMotionFilter: cameras.some(function(camera) { return camera.id === motionCameraFilter })
        ? motionCameraFilter : ""
    property bool tabAnimating: false  // the card's height eases while switching tabs
    // Latest motion per camera from motiond's status: id -> {date, time}.
    property var lastMotionByCamera: ({})
    property bool fullscreen: false
    property bool pinned: false
    property bool configured: false
    property var cameras: []
    property string selectedCameraId: ""
    property string editingCameraId: ""
    property bool deleteArmed: false
    readonly property int selectedCameraIndex: cameras.findIndex(function(camera) { return camera.id === root.selectedCameraId })
    property string message: ""
    property alias playbackMessage: primaryFeed.playbackMessage
    property alias receivedFrame: primaryFeed.receivedFrame
    property alias framesReceived: primaryFeed.framesReceived
    property real viewerWidth: 640
    property real viewerHeight: 500
    property bool sizeDirty: false
    property string sizeSaveError: ""
    property string positionSaveError: ""
    property string videoStyle: "theme"
    property int tintStrength: 35
    property int pixelSize: 3
    property string overlayStyle: "default"
    readonly property var overlayStyles: ["default", "coder", "hacker"]
    property string appearanceMessage: ""
    property bool editingAppearance: false
    readonly property var videoStyles: ["original", "theme", "pixel", "theme-pixel"]
    property var pendingPosition: null
    property alias retryAttempt: primaryFeed.retryAttempt
    property var config: ({url: "rtsp://", username: "", password: ""})
    readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
    readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/rtsp-camera/config.json"
    readonly property bool streaming: opened && !configuring && !browsing && configured
    readonly property bool live: primaryFeed.live
    property bool dualView: true
    property string focusedCameraId: ""
    // Each player stays bound to its own camera; enlarging one only hides the
    // other tile, so neither stream reconnects on the way in or out.
    readonly property bool dualStreaming: dualView && cameras.length > 1
    readonly property var primaryCamera: config
    readonly property var secondaryCamera: cameras.find(function(camera) { return camera.id !== root.config.id }) || ({})
    // A focus that no longer matches a tile (e.g. another camera was picked) is ignored.
    readonly property string focusId: focusedCameraId !== "" && dualStreaming
        && (focusedCameraId === (primaryCamera.id || "") || focusedCameraId === (secondaryCamera.id || ""))
        ? focusedCameraId : ""
    readonly property bool dualActive: dualStreaming && focusId === ""
    // Full screen pins the card so it can sit centered; leaving restores the
    // pin state and position the viewer had before.
    property bool pinnedBeforeFullscreen: false
    property point originBeforeFullscreen: Qt.point(0, 0)
    onFullscreenChanged: {
        if (fullscreen) return
        focusedCameraId = ""
        // Raw origin: cardOrigin bounds it against the card size it has once restored.
        if (pinnedBeforeFullscreen) popup.pinnedOrigin = originBeforeFullscreen
        else pinned = false
    }

    function toggleDualView() {
        fullscreen = false
        focusedCameraId = ""
        dualView = !dualView
    }
    function enlargeCamera(id) {
        // In dual view (windowed or full screen) a tile's button focuses that
        // camera; on the focused tile, or in single view, it toggles full screen.
        if (dualStreaming && id && focusId !== id) {
            focusedCameraId = id
            if (id === (primaryCamera.id || "")) secondaryFeed.mute()
            else primaryFeed.mute()
            if (!fullscreen) toggleFullscreen()
            return
        }
        toggleFullscreen()
    }
    function play(resetRetry) { primaryFeed.play(resetRetry) }
    function scheduleReconnect(reason) { primaryFeed.scheduleReconnect(reason) }
    function toggleFeedAudio(feed) {
        if (feed === primaryFeed) secondaryFeed.mute()
        else primaryFeed.mute()
        feed.toggleAudio()
    }

    function openMotionGallery() {
        if (!configured) return
        editingAppearance = false
        configuring = false
        showingRecordings = false
        showingMotion = true
    }
    function closeMotionGallery() {
        showingMotion = false
    }
    function openRecordings() {
        if (!configured) return
        editingAppearance = false
        configuring = false
        showingMotion = false
        showingRecordings = true
    }
    function closeRecordings() {
        showingRecordings = false
    }
    // Watch a moment in Recordings (from a motion still or Live's last-motion chip):
    // 3 s before it, on that camera and day.
    function openRecordingsAt(cameraId, day, time, from) {
        var parts = String(time).split(":")
        if (parts.length !== 3 || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return
        var at = Math.max(0, (+parts[0]) * 3600 + (+parts[1]) * 60 + (+parts[2]) - 3)
        recordingsView.openAt(cameraId, day, at)
        recordingsView.returnTo = from || ""
        var index = cameras.findIndex(function(camera) { return camera.id === cameraId })
        if (index >= 0 && index !== selectedCameraIndex) runProfileOperation({action: "select", id: cameraId})
        openRecordings()
    }
    function lastMotionFor(cameraId) {
        var event = lastMotionByCamera[cameraId || ""]
        return event && event.date === Qt.formatDate(new Date(), "yyyy-MM-dd") ? event.time.slice(0, 5) : ""
    }
    function openLastMotion(cameraId) {
        var event = lastMotionByCamera[cameraId || ""]
        if (event) openRecordingsAt(cameraId, event.date, event.time)
    }
    // After a menu or a tab, keys go back to the view (Space, arrows...).
    function refocusView() {
        if (showingRecordings) recordingsView.forceActiveFocus()
        else if (showingMotion) motionGallery.forceActiveFocus()
        else content.forceActiveFocus()
    }
    function animateTabChange() {
        tabAnimating = true
        tabAnimationEnd.restart()
    }
    function showTab(index) {
        if (!configured) return
        animateTabChange()
        Qt.callLater(refocusView)
        if (index === 1) openMotionGallery()
        else if (index === 2) openRecordings()
        else {
            closeMotionGallery()
            closeRecordings()
            if (configuring && configured) { password.text = ""; configuring = false }
        }
    }
    function toggleFullscreen() {
        if (!configured || configuring) return
        if (!fullscreen) {
            pinnedBeforeFullscreen = pinned
            originBeforeFullscreen = popup.pinnedOrigin
        }
        fullscreen = !fullscreen
        if (fullscreen) {
            pinned = true
            Qt.callLater(function() {
                if (!root.fullscreen || !popup.screen) return
                popup.pinnedOrigin = Qt.point(
                    Math.round((popup.screenW - popup.contentWidth) / 2),
                    Math.round((popup.screenH - popup.contentHeight) / 2))
            })
        }
    }
    function exitFullscreenIfActive(event) {
        if (!fullscreen) return false
        fullscreen = false
        if (event) event.accepted = true
        return true
    }
    function editSettings(newCamera) {
        editingAppearance = false
        showingMotion = false
        showingRecordings = false
        fullscreen = false
        editingCameraId = newCamera === true ? "" : selectedCameraId
        cameraName.text = newCamera === true ? "" : selectedCameraIndex >= 0 ? cameras[selectedCameraIndex].name : "Camera 1"
        address.text = newCamera === true ? "rtsp://" : config.url
        username.text = newCamera === true ? "" : config.username
        password.text = newCamera === true ? "" : config.password
        deleteArmed = false
        message = ""
        configuring = true
        cameraName.forceActiveFocus()
    }
    function toggleAppearance() {
        if (appearanceWriter.running) return
        if (editingAppearance) {
            editingAppearance = false
            return
        }
        videoStyleChooser.currentIndex = videoStyles.indexOf(videoStyle)
        tintSlider.value = tintStrength
        pixelSlider.value = pixelSize
        overlayChooser.currentIndex = overlayStyles.indexOf(overlayStyle)
        appearanceMessage = ""
        editingAppearance = true
    }
    onConfiguringChanged: if (configuring) editingAppearance = false
    function applyLibrary(data) {
        // Existing single-camera settings migrate when first edited or selected.
        if (!Array.isArray(data.cameras)) {
            data = {version: 2, selectedId: "default", cameras: [{id: "default", name: "Camera 1",
                url: data.url, username: data.username, password: data.password}]}
        }
        if (data.version !== 2 || data.cameras.length > 32 || typeof data.selectedId !== "string") throw new Error()
        var ids = Object.create(null), names = Object.create(null)
        data.cameras.forEach(function(camera) {
            if (!camera || typeof camera.id !== "string" || !camera.id || ids[camera.id]
                || typeof camera.name !== "string" || !camera.name.trim() || names[camera.name.toLowerCase()]
                || typeof camera.url !== "string" || !/^rtsps?:\/\//.test(camera.url)
                || typeof camera.username !== "string" || typeof camera.password !== "string") throw new Error()
            ids[camera.id] = true
            names[camera.name.toLowerCase()] = true
        })
        var selected = data.cameras.find(function(camera) { return camera.id === data.selectedId })
        if ((data.cameras.length && !selected) || (!data.cameras.length && data.selectedId !== "")) throw new Error()
        var changed = selectedCameraId !== data.selectedId
            || (selected && (selected.url !== config.url || selected.username !== config.username || selected.password !== config.password))
        cameras = data.cameras
        selectedCameraId = data.selectedId
        config = selected || {url: "rtsp://", username: "", password: ""}
        configured = !!selected
        if (!opened || !configured) configuring = !configured
        if (changed) primaryFeed.mute()
    }
    function runProfileOperation(operation) {
        if (writer.running) return
        message = ""
        writer.stayInSettings = configuring && operation.action === "select"
        writer.pending = JSON.stringify(operation)
        writer.running = true
    }
    function selectCamera(index) {
        if (writer.running || index < 0 || index >= cameras.length) return
        showingMotion = false
        if (index === selectedCameraIndex) {
            if (configuring) editSettings()
            return
        }
        runProfileOperation({action: "select", id: cameras[index].id})
    }
    function submitProfile() {
        runProfileOperation({action: "save", camera: {id: editingCameraId, name: cameraName.text,
            url: address.text, username: username.text, password: password.text}})
    }
    function playbackStatus() {
        return JSON.stringify(Object.assign(primaryFeed.status(), {
            width: popup.contentWidth, height: popup.contentHeight,
            fullscreen: fullscreen,
            sizePending: sizeDirty || sizeWriter.running, sizeSaveError: sizeSaveError,
            pinned: pinned, inputWidth: popup.mask.width, inputHeight: popup.mask.height,
            x: popup.cardOrigin.x, y: popup.cardOrigin.y,
            positionPending: !!pendingPosition || positionWriter.running,
            positionSaveError: positionSaveError,
            cameraCount: cameras.length, selectedCameraId: selectedCameraId,
            showingMotion: showingMotion,
            showingRecordings: showingRecordings,
            viewMode: dualActive ? "dual" : focusId ? "focus" : "single",
            feeds: dualStreaming ? [primaryFeed.status(), secondaryFeed.status()] : [primaryFeed.status()]}))
    }
    function resizeViewer(width, height) {
        viewerWidth = Math.round(Math.min(popup.availableCardWidth, Math.max(420, width)))
        viewerHeight = Math.round(Math.min(popup.availableCardHeight, Math.max(440, height)))
        sizeDirty = true
        sizeSaveTimer.restart()
    }
    function saveViewerSize() {
        if (!sizeDirty || sizeWriter.running) return
        sizeWriter.pending = JSON.stringify({width: viewerWidth, height: viewerHeight})
        sizeDirty = false
        sizeWriter.running = true
    }
    function toggleAudio() { toggleFeedAudio(primaryFeed) }
    function saveViewerPosition() {
        if (!pendingPosition || positionWriter.running) return
        positionWriter.pending = JSON.stringify(pendingPosition)
        pendingPosition = null
        positionWriter.running = true
    }
    onOpenedChanged: {
        if (!opened) {
            editingAppearance = false
            showingMotion = false
            showingRecordings = false
            fullscreen = false
            writer.stayInSettings = false
            pinned = false
            sizeSaveTimer.stop()
            saveViewerSize()
            positionSaveTimer.stop()
            saveViewerPosition()
        }
        if (opened) {
            configuring = !configured
            showingMotion = false
            showingRecordings = false
            fullscreen = false
            if (configuring) editSettings()
        }
    }

    FileView {
        id: appearanceFile
        path: root.configPath.replace(/config\.json$/, "appearance.json")
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                var saved = JSON.parse(text())
                var savedPixelSize = saved.pixelSize === undefined ? 3 : saved.pixelSize
                var savedOverlay = saved.overlay === undefined ? "default" : saved.overlay
                if (savedOverlay === "off") savedOverlay = "default"
                else if (savedOverlay === "hud") savedOverlay = "coder"
                else if (savedOverlay === "terminal") savedOverlay = "hacker"
                if (root.videoStyles.indexOf(saved.style) < 0 || typeof saved.strength !== "number"
                    || !Number.isInteger(saved.strength) || saved.strength < 0 || saved.strength > 100
                    || !Number.isInteger(savedPixelSize) || savedPixelSize < 1 || savedPixelSize > 16
                    || root.overlayStyles.indexOf(savedOverlay) < 0) return
                root.videoStyle = saved.style
                root.tintStrength = saved.strength
                root.pixelSize = savedPixelSize
                root.overlayStyle = savedOverlay
            } catch (error) { /* Missing or invalid appearance keeps the default. */ }
        }
    }
    Process {
        id: appearanceWriter
        property string pending: ""
        command: ["python3", Qt.resolvedUrl("config.py").toString().replace(/^file:\/\//, ""), "--appearance"]
        stdinEnabled: true
        onStarted: write(pending + "\n")
        onExited: function(code) {
            if (code !== 0) {
                root.appearanceMessage = "Could not save video style. Try again."
                return
            }
            // Commit the exact submitted preview before hiding the editor.
            var saved = JSON.parse(pending)
            root.videoStyle = saved.style
            root.tintStrength = saved.strength
            root.pixelSize = saved.pixelSize
            root.overlayStyle = saved.overlay
            root.appearanceMessage = ""
            root.editingAppearance = false
            appearanceFile.reload()
        }
    }
    FileView {
        id: positionFile
        readonly property string monitorName: popup.screen ? popup.screen.name : ""
        path: monitorName ? root.configPath.replace(/config\.json$/, "position-" + encodeURIComponent(monitorName) + ".json") : ""
        watchChanges: true
        printErrors: false
        onPathChanged: popup.savedPosition = null
        onFileChanged: reload()
        onLoaded: {
            if (root.pendingPosition || positionWriter.running) return
            try {
                var saved = JSON.parse(text())
                if (saved.screen !== monitorName || typeof saved.x !== "number" || typeof saved.y !== "number"
                    || !isFinite(saved.x) || !isFinite(saved.y)
                    || saved.x < 0 || saved.y < 0 || saved.x > 32768 || saved.y > 32768) return
                popup.savedPosition = Qt.point(saved.x, saved.y)
                if (popup.pinned) popup.pinnedOrigin = popup.boundedOrigin(popup.savedPosition)
            } catch (error) { /* No saved position: use the bar anchor. */ }
        }
    }
    Timer {
        id: positionSaveTimer
        interval: 300
        onTriggered: root.saveViewerPosition()
    }
    Process {
        id: positionWriter
        property string pending: ""
        command: ["python3", Qt.resolvedUrl("config.py").toString().replace(/^file:\/\//, ""), "--position"]
        stdinEnabled: true
        onStarted: { write(pending + "\n"); pending = "" }
        onExited: function(code) {
            root.positionSaveError = code === 0 ? "" : "Could not remember viewer position"
            if (root.pendingPosition) positionSaveTimer.restart()
        }
    }
    FileView {
        id: sizeFile
        path: root.configPath.replace(/config\.json$/, "view.json")
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            if (root.sizeDirty || sizeWriter.running) return
            try {
                var size = JSON.parse(text())
                if (typeof size.width !== "number" || typeof size.height !== "number"
                    || !isFinite(size.width) || !isFinite(size.height)
                    || size.width < 1 || size.height < 1
                    || size.width > 32768 || size.height > 32768) return
                root.viewerWidth = size.width
                root.viewerHeight = size.height
            } catch (error) { /* Missing or invalid size uses the defaults. */ }
        }
    }
    Timer {
        id: sizeSaveTimer
        interval: 300
        onTriggered: root.saveViewerSize()
    }
    Process {
        id: sizeWriter
        property string pending: ""
        command: ["python3", Qt.resolvedUrl("config.py").toString().replace(/^file:\/\//, ""), "--view-size"]
        stdinEnabled: true
        onStarted: { write(pending + "\n"); pending = "" }
        onExited: function(code) {
            root.sizeSaveError = code === 0 ? "" : "Could not remember viewer size"
            if (root.sizeDirty) sizeSaveTimer.restart()
        }
    }
    Timer { id: tabAnimationEnd; interval: 260; onTriggered: root.tabAnimating = false }
    // Live's "last motion" chips: motiond's status has each camera's latest event.
    Process {
        id: motionStatus
        command: ["python3", Qt.resolvedUrl("motiond.py").toString().replace(/^file:\/\//, ""), "--status"]
        stdout: StdioCollector { id: motionStatusOut }
        onExited: function(code) {
            var latest = {}
            try {
                var cameras = JSON.parse(motionStatusOut.text || "{}").cameras || {}
                for (var id in cameras) {
                    var info = cameras[id] || {}
                    var stamp = String(info.lastEvent || "")
                    if (info.source === "dvrip" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(stamp))
                        latest[id] = {date: stamp.slice(0, 10), time: stamp.slice(11, 19)}
                }
            } catch (error) {}
            root.lastMotionByCamera = latest
        }
    }
    Timer {
        interval: 30000
        repeat: true
        triggeredOnStart: true
        running: root.streaming
        onTriggered: { motionStatus.running = false; motionStatus.running = true }
    }
    FileView {
        id: configFile
        path: root.configPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            if (writer.running) return
            try {
                root.applyLibrary(JSON.parse(text()))
            } catch (error) {
                root.configured = false
                root.configuring = true
                root.message = "Saved settings could not be read. Enter them again to repair the file."
            }
        }
        onLoadFailed: {
            root.configured = false
            root.configuring = true
        }
    }
    Process {
        id: writer
        property string pending: ""
        property bool stayInSettings: false
        command: ["python3", Qt.resolvedUrl("config.py").toString().replace(/^file:\/\//, ""), "--profiles"]
        stdinEnabled: true
        onStarted: { write(pending + "\n"); pending = "" }
        stdout: StdioCollector { id: saveResult }
        onExited: function(code) {
            if (code !== 0) {
                root.message = saveResult.text.trim() || "Unable to save settings."
                return
            }
            try { root.applyLibrary(JSON.parse(saveResult.text)) }
            catch (error) { root.message = "Saved camera profiles could not be read."; return }
            root.message = ""
            root.configuring = stayInSettings || !root.configured
            password.text = ""
            root.deleteArmed = false
            if (!root.configured) root.editSettings(true)
            else if (stayInSettings) root.editSettings()
            configFile.reload()
        }
    }
    CameraPopup {
        id: popup
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        pinned: root.pinned
        // The camera menu renders outside the card; don't fade chrome while it is open.
        chromeForce: cameraSelector.popup.opened
        onChromeForceChanged: {
            if (chromeForce) Qt.callLater(refreshExtraInput)
            else extraInput = Qt.rect(0, 0, 0, 0)
        }
        onCardOriginChanged: if (chromeForce) Qt.callLater(refreshExtraInput)
        onPositionMoved: function(x, y) {
            if (!screen) return
            root.pendingPosition = {screen: screen.name, x: Math.round(x), y: Math.round(y)}
            positionSaveTimer.restart()
        }
        // Pinned input mask is the card rect only — include the open camera menu
        // so rows that hang past the card stay clickable.
        function refreshExtraInput() {
            var extra = Qt.rect(0, 0, 0, 0)
            if (cameraSelector.popup.opened) {
                var surface = cameraSelector.popup.contentItem || cameraSelector.popup
                var origin = surface.mapToItem(null, 0, 0)
                extra = Qt.rect(origin.x, origin.y, surface.width, surface.height)
            }
            extraInput = extra
        }
        contentWidth: root.fullscreen
            ? popup.availableCardWidth
            : fittedContentWidth(root.viewerWidth)
        // Like Picture in Picture, the live view hugs the video: the saved
        // height is only an upper bound, so the stream is never letterboxed
        // vertically inside the card. Settings fit their form the same way.
        readonly property real chromeHeight: verticalContentInset + headerControls.implicitHeight + 10 + 8
        readonly property real liveNaturalHeight: {
            var width = feedGrid.width
            if (width <= 0) return root.viewerHeight
            var lead = root.focusId !== "" && root.focusId === (root.secondaryCamera.id || "") ? secondaryFeed : primaryFeed
            var grid = width / lead.aspect
            if (root.dualActive && feedGrid.columns === 2) {
                var column = (width - feedGrid.columnSpacing) / 2
                grid = Math.max(column / primaryFeed.aspect, column / secondaryFeed.aspect)
            } else if (root.dualActive) {
                grid = width / primaryFeed.aspect + feedGrid.rowSpacing + width / secondaryFeed.aspect
            }
            grid = Math.max(grid, feedGrid.Layout.minimumHeight)
            var editor = root.editingAppearance ? viewerPage.spacing + themeEditor.naturalHeight : 0
            return chromeHeight + grid + editor
        }
        readonly property real pageNaturalHeight: root.configuring ? chromeHeight + settingsColumn.implicitHeight
            : root.browsing ? root.viewerHeight : liveNaturalHeight
        Behavior on contentHeight {
            enabled: root.tabAnimating && !root.fullscreen
            NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic }
        }
        contentHeight: root.fullscreen
            ? popup.availableCardHeight
            // The appearance inspector grows the card to fit while it is open.
            : cappedContentHeight(root.editingAppearance ? Math.ceil(pageNaturalHeight)
                : Math.min(root.viewerHeight, Math.ceil(pageNaturalHeight)))
        focusTarget: content

        FocusScope {
            id: content
            anchors.fill: parent
            Keys.onPressed: function(event) {
                if (root.configuring || event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
                if (event.key === Qt.Key_F) root.toggleFullscreen()
                else if (event.key === Qt.Key_L) root.showTab(0)
                else if (event.key === Qt.Key_M) root.showTab(1)
                else if (event.key === Qt.Key_R) root.showTab(2)
                else return
                event.accepted = true
            }
            Keys.onEscapePressed: function(event) {
                if (root.exitFullscreenIfActive(event)) return
                if (root.showingMotion) {
                    root.closeMotionGallery()
                    event.accepted = true
                    return
                }
                if (root.showingRecordings) {
                    root.closeRecordings()
                    event.accepted = true
                    return
                }
                root.close()
            }
            ColumnLayout {
                anchors.fill: parent
                anchors.bottomMargin: 8
                spacing: 10
                // Toolbar: window controls, camera menu, view switcher, actions.
                Item {
                    Layout.fillWidth: true
                    implicitHeight: headerControls.implicitHeight
                    opacity: popup.chromeOpacity
                    MouseArea {
                        anchors.fill: parent
                        enabled: root.opened && root.pinned
                        hoverEnabled: true
                        preventStealing: true
                        acceptedButtons: Qt.LeftButton
                        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                        property point dragStart
                        property point startOrigin
                        onPressed: function(mouse) {
                            dragStart = mapToItem(null, mouse.x, mouse.y)
                            startOrigin = popup.cardOrigin
                        }
                        onPositionChanged: function(mouse) {
                            if (!pressed) return
                            var point = mapToItem(null, mouse.x, mouse.y)
                            popup.movePinned(startOrigin.x + point.x - dragStart.x,
                                startOrigin.y + point.y - dragStart.y)
                        }
                        PanelToolTip {
                            visible: parent.containsMouse && !parent.pressed
                            text: strings.t("toolbar.drag")
                            fontSize: Style.font.caption
                        }
                    }
                    RowLayout {
                        id: headerControls
                        objectName: "toolbar"
                        readonly property bool compact: width < 620
                        anchors.fill: parent
                        spacing: 8
                        Controls.ComboBox {
                            id: cameraSelector
                            objectName: "cameraSelector"
                            readonly property real naturalWidth: 18 + selectorName.advanceWidth + 7 + 14
                                + (root.configured && !root.configuring ? 8 + 7 : 0)
                            TextMetrics {
                                id: selectorName
                                font.family: ui.font
                                font.pixelSize: ui.body
                                font.weight: Font.DemiBold
                                text: cameraSelector.displayText
                            }
                            Layout.fillWidth: true
                            Layout.minimumWidth: 72
                            Layout.maximumWidth: Math.min(naturalWidth, 280)
                            Layout.preferredWidth: Math.min(naturalWidth, 280)
                            implicitHeight: ui.controlHeight
                            readonly property bool filtering: root.showingMotion && root.cameras.length > 1
                            readonly property int filterIndex: root.activeMotionFilter === "" ? 0
                                : 1 + root.cameras.findIndex(function(camera) { return camera.id === root.activeMotionFilter })
                            model: filtering ? [{id: "", name: strings.t("motion.allCameras")}].concat(root.cameras) : root.cameras
                            textRole: "name"
                            currentIndex: filtering ? filterIndex : root.selectedCameraIndex
                            displayText: root.cameras.length ? currentText : strings.t("menu.noCameras")
                            enabled: !writer.running && root.cameras.length > 0
                            hoverEnabled: true
                            Accessible.name: strings.t("menu.select")
                            onActivated: function(index) {
                                if (filtering) {
                                    root.motionCameraFilter = index === 0 ? "" : root.cameras[index - 1].id
                                    if (index > 0 && index - 1 !== root.selectedCameraIndex)
                                        root.runProfileOperation({action: "select", id: root.cameras[index - 1].id})
                                } else root.selectCamera(index)
                                Qt.callLater(root.refocusView)
                            }
                            contentItem: Item {
                                Row {
                                    id: selectorRow
                                    x: 9
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 7
                                    StatusDot {
                                        id: selectorDot
                                        objectName: "headerStatusDot"
                                        visible: root.configured && !root.configuring
                                        opacity: root.browsing ? 0 : 1
                                        anchors.verticalCenter: parent.verticalCenter
                                        tone: primaryFeed.statusColor
                                        pulsing: primaryFeed.connecting
                                    }
                                    Text {
                                        objectName: "selectorTitle"
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.min(implicitWidth, Math.max(0, cameraSelector.width - 18 - 7 - chevron.width
                                            - (selectorDot.visible ? selectorDot.width + 7 : 0)))
                                        textFormat: Text.PlainText
                                        text: cameraSelector.displayText
                                        color: cameraSelector.enabled ? ui.label : ui.secondaryLabel
                                        font.family: ui.font
                                        font.pixelSize: ui.body
                                        font.weight: Font.DemiBold
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        id: chevron
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: root.cameras.length > 0
                                        textFormat: Text.PlainText
                                        text: ui.iconChevronDown
                                        font.family: ui.iconFont
                                        font.pixelSize: 14
                                        color: ui.secondaryLabel
                                    }
                                }
                            }
                            indicator: null
                            background: Rectangle {
                                radius: ui.controlRadius
                                color: cameraSelector.popup.opened ? ui.fillHover
                                    : cameraSelector.hovered && cameraSelector.enabled ? ui.fill : "transparent"
                                border.width: cameraSelector.visualFocus ? 2 : 0
                                border.color: ui.alpha(ui.accent, 0.8)
                            }
                            delegate: Controls.ItemDelegate {
                                id: cameraRow
                                required property var modelData
                                required property int index
                                width: cameraSelector.popup.availableWidth
                                height: 28
                                text: modelData.name
                                highlighted: cameraSelector.highlightedIndex === index
                                hoverEnabled: true
                                contentItem: Row {
                                    spacing: 6
                                    Text {
                                        width: 16
                                        anchors.verticalCenter: parent.verticalCenter
                                        textFormat: Text.PlainText
                                        text: cameraRow.index === cameraSelector.currentIndex ? ui.iconCheck : ""
                                        font.family: ui.iconFont
                                        font.pixelSize: 13
                                        color: cameraRow.highlighted || cameraRow.hovered ? ui.onAccent : ui.label
                                        horizontalAlignment: Text.AlignHCenter
                                    }
                                    Text {
                                        width: cameraRow.width - 40
                                        anchors.verticalCenter: parent.verticalCenter
                                        textFormat: Text.PlainText
                                        text: cameraRow.text
                                        font.family: ui.font
                                        font.pixelSize: ui.body
                                        color: cameraRow.highlighted || cameraRow.hovered ? ui.onAccent : ui.label
                                        elide: Text.ElideRight
                                    }
                                }
                                leftPadding: 6
                                rightPadding: 8
                                background: Rectangle {
                                    radius: 5
                                    color: cameraRow.highlighted || cameraRow.hovered ? ui.accent : "transparent"
                                }
                                PointerArea {}
                            }
                            popup: Controls.Popup {
                                y: cameraSelector.height + 4
                                width: Math.max(220, cameraSelector.width)
                                padding: 5
                                focus: true
                                enter: Transition {
                                    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Style.duration(140); easing.type: Easing.OutCubic }
                                    NumberAnimation { property: "scale"; from: 0.97; to: 1; duration: Style.duration(140); easing.type: Easing.OutCubic }
                                }
                                exit: Transition {
                                    NumberAnimation { property: "opacity"; to: 0; duration: Style.duration(100); easing.type: Easing.OutCubic }
                                }
                                contentItem: Column {
                                    spacing: 4
                                    ListView {
                                        id: cameraList
                                        width: parent.width
                                        height: Math.min(260, contentHeight)
                                        clip: true
                                        spacing: 1
                                        boundsBehavior: Flickable.StopAtBounds
                                        model: cameraSelector.popup.visible ? cameraSelector.delegateModel : null
                                        currentIndex: cameraSelector.highlightedIndex
                                        Controls.ScrollIndicator.vertical: Controls.ScrollIndicator {}
                                    }
                                    Rectangle {
                                        width: parent.width - 12
                                        x: 6
                                        height: 1
                                        color: ui.separator
                                    }
                                    Controls.ItemDelegate {
                                        id: addFromMenu
                                        objectName: "menuAddCamera"
                                        width: parent.width
                                        height: 28
                                        text: strings.t("menu.addCamera")
                                        enabled: root.cameras.length < 32 && !writer.running
                                        hoverEnabled: true
                                        leftPadding: 28
                                        contentItem: Text {
                                            textFormat: Text.PlainText
                                            text: addFromMenu.text
                                            font.family: ui.font
                                            font.pixelSize: ui.body
                                            color: addFromMenu.hovered ? ui.onAccent : ui.label
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                        background: Rectangle {
                                            radius: 5
                                            color: addFromMenu.hovered ? ui.accent : "transparent"
                                        }
                                        onClicked: {
                                            cameraSelector.popup.close()
                                            root.editSettings(true)
                                        }
                                        PointerArea {}
                                    }
                                }
                                background: Rectangle {
                                    radius: 10
                                    color: ui.menuBackground
                                    border.width: 1
                                    border.color: ui.alpha(ui.label, 0.14)
                                }
                            }
                            PointerArea {}
                        }
                        Item {
                            objectName: "headerDragSpace"
                            Layout.fillWidth: true
                            Layout.minimumWidth: 12
                            Layout.fillHeight: true
                        }
                        MacSegmented {
                            id: viewModeControl
                            objectName: "viewModeControl"
                            model: [strings.t("view.live"), strings.t("view.motion"), strings.t("view.recordings")]
                            icons: headerControls.compact ? [ui.iconLive, ui.iconMotion, ui.iconHistory] : []
                            segmentNames: ["liveButton", "motionButton", "recordingsButton"]
                            iconOnly: headerControls.compact
                            autoSelect: false
                            currentIndex: root.configuring ? -1 : root.showingMotion ? 1 : root.showingRecordings ? 2 : 0
                            enabled: !writer.running && root.configured
                            opacity: enabled ? 1 : 0.5
                            tips: [strings.t("view.liveTip") + " (L)", strings.t("view.motionTip") + " (M)",
                                strings.t("view.recordingsTip") + " (R)"]
                            onActivated: function(index) { root.showTab(index) }
                        }
                        RowLayout {
                            spacing: 2
                            MacToolbarButton {
                                objectName: "dualViewButton"
                                glyph: ui.iconSplit
                                tipText: root.dualView ? strings.t("layout.showSingle") : strings.t("layout.showBoth")
                                Accessible.name: strings.t("layout.twoCameras")
                                visible: !root.configuring
                                opacity: root.browsing ? 0 : 1
                                enabled: root.cameras.length > 1 && !root.browsing
                                checked: root.dualView && root.cameras.length > 1
                                onClicked: root.toggleDualView()
                            }
                            MacToolbarButton {
                                objectName: "themeButton"
                                glyph: ui.iconPalette
                                tipText: strings.t("toolbar.appearance")
                                visible: !root.configuring
                                opacity: root.browsing ? 0 : 1
                                enabled: !root.browsing
                                checked: root.editingAppearance
                                onClicked: root.toggleAppearance()
                            }
                            MacToolbarButton {
                                objectName: "configButton"
                                glyph: ui.iconSettings
                                tipText: strings.t("toolbar.settings")
                                enabled: !writer.running
                                checked: root.configuring
                                onClicked: {
                                    if (root.configuring && root.configured) {
                                        password.text = ""
                                        root.configuring = false
                                    } else root.editSettings()
                                }
                            }
                            MacToolbarButton {
                                objectName: "fullscreenToolbarButton"
                                glyph: root.fullscreen ? ui.iconFullscreenExit : ui.iconFullscreen
                                tipText: (root.fullscreen ? strings.t("window.exitFullScreen") : strings.t("window.fullScreen")) + " (F)"
                                visible: !root.configuring  // every tab: Recordings needs the room most
                                enabled: root.configured
                                checked: root.fullscreen
                                onClicked: root.toggleFullscreen()
                            }
                            MacToolbarButton {
                                id: pinSwitch
                                objectName: "pinSwitch"
                                glyph: root.pinned ? ui.iconPin : ui.iconPinOutline
                                opacity: root.browsing ? 0 : 1
                                enabled: !root.browsing
                                checked: root.pinned
                                tipText: root.pinned ? strings.t("toolbar.unpin") : strings.t("toolbar.pin")
                                onClicked: root.pinned = !root.pinned
                            }
                        }
                    }
                }
                StackLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    currentIndex: root.configuring ? 1 : root.showingMotion ? 2 : root.showingRecordings ? 3 : 0
                    ColumnLayout {
                        id: viewerPage
                        spacing: 10
                        GridLayout {
                            id: feedGrid
                            objectName: "feedGrid"
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.minimumHeight: root.dualActive && columns === 1 ? 240 : 120
                            columns: root.dualActive && width >= 720 ? 2 : 1
                            columnSpacing: 8
                            rowSpacing: 8
                            CameraFeed {
                                id: primaryFeed
                                objectName: "primaryFeed"
                                visible: root.focusId === "" || root.focusId === (root.primaryCamera.id || "")
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                Layout.preferredWidth: 1
                                Layout.preferredHeight: 1
                                camera: root.primaryCamera
                                streaming: root.streaming
                                compact: root.dualActive || root.focusId !== ""
                                fullscreen: root.fullscreen
                                videoStyle: root.editingAppearance ? root.videoStyles[videoStyleChooser.currentIndex] : root.videoStyle
                                tintStrength: root.editingAppearance ? tintSlider.value : root.tintStrength
                                pixelSize: root.editingAppearance ? Math.round(pixelSlider.value) : root.pixelSize
                                overlayStyle: root.editingAppearance ? root.overlayStyles[overlayChooser.currentIndex] : root.overlayStyle
                                message: root.message || root.sizeSaveError || root.positionSaveError
                                onAudioRequested: root.toggleFeedAudio(primaryFeed)
                                onFullscreenRequested: root.enlargeCamera(camera.id || "")
                                lastMotion: root.lastMotionFor(camera.id)
                                onLastMotionRequested: root.openLastMotion(camera.id)
                            }
                            CameraFeed {
                                id: secondaryFeed
                                objectName: "secondaryFeed"
                                visible: root.dualActive || (root.focusId !== "" && root.focusId === (root.secondaryCamera.id || ""))
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                Layout.preferredWidth: 1
                                Layout.preferredHeight: 1
                                camera: root.secondaryCamera
                                streaming: root.streaming && root.dualStreaming
                                compact: true
                                fullscreen: root.fullscreen
                                videoStyle: primaryFeed.videoStyle
                                tintStrength: primaryFeed.tintStrength
                                pixelSize: primaryFeed.pixelSize
                                overlayStyle: primaryFeed.overlayStyle
                                onAudioRequested: root.toggleFeedAudio(secondaryFeed)
                                onFullscreenRequested: root.enlargeCamera(camera.id || "")
                                lastMotion: root.lastMotionFor(camera.id)
                                onLastMotionRequested: root.openLastMotion(camera.id)
                            }
                        }
                        // Appearance inspector: live preview, applied to every camera.
                        Rectangle {
                            id: themeEditor
                            objectName: "themeEditor"
                            visible: root.editingAppearance
                            Layout.fillWidth: true
                            readonly property real naturalHeight: appearanceColumn.implicitHeight + appearanceTitle.implicitHeight
                                + appearanceFooter.implicitHeight + 52
                            Layout.preferredHeight: Math.min(naturalHeight, viewerPage.height * 0.62)
                            radius: 12
                            color: ui.groupFill
                            border.width: 1
                            border.color: ui.groupBorder
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 14
                                spacing: 12
                                RowLayout {
                                    id: appearanceTitle
                                    Layout.fillWidth: true
                                    MacText {
                                        text: strings.t("appearance.title")
                                        font.pixelSize: ui.headline
                                        font.weight: Font.DemiBold
                                    }
                                    Item { Layout.fillWidth: true }
                                    MacText {
                                        text: strings.t("appearance.scope")
                                        color: ui.secondaryLabel
                                        font.pixelSize: ui.caption
                                    }
                                }
                                Controls.ScrollView {
                                    id: appearanceScroll
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    clip: true
                                    contentWidth: availableWidth
                                    Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff
                                    ColumnLayout {
                                        id: appearanceColumn
                                        width: appearanceScroll.availableWidth
                                        spacing: 8
                                        SectionLabel { text: strings.t("appearance.style") }
                                        MacSegmented {
                                            id: videoStyleChooser
                                            objectName: "videoStyle"
                                            Layout.fillWidth: true
                                            model: ["Original", "Omarchy", "Pixel", "Omarchy Pixel"]
                                            currentIndex: root.videoStyles.indexOf(root.videoStyle)
                                            enabled: !appearanceWriter.running
                                            Accessible.name: strings.t("appearance.style")
                                        }
                                        RowLayout {
                                            visible: tintSlider.visible
                                            Layout.fillWidth: true
                                            Layout.topMargin: 6
                                            SectionLabel { text: strings.t("appearance.tint") }
                                            Item { Layout.fillWidth: true }
                                            MacText {
                                                text: Commons.I18n.formatNumber(Math.round(tintSlider.value)) + "%"
                                                color: ui.secondaryLabel
                                                font.pixelSize: ui.callout
                                                font.features: { "tnum": 1 }
                                            }
                                        }
                                        MacSlider {
                                            id: tintSlider
                                            objectName: "tintStrength"
                                            visible: videoStyleChooser.currentIndex === 1 || videoStyleChooser.currentIndex === 3
                                            Layout.fillWidth: true
                                            from: 0; to: 100; stepSize: 1
                                            value: root.tintStrength
                                            enabled: !appearanceWriter.running
                                            Accessible.name: strings.t("appearance.tint")
                                        }
                                        RowLayout {
                                            visible: pixelSlider.visible
                                            Layout.fillWidth: true
                                            Layout.topMargin: 6
                                            SectionLabel { text: strings.t("appearance.pixel") }
                                            Item { Layout.fillWidth: true }
                                            MacText {
                                                text: Commons.I18n.formatNumber(Math.round(pixelSlider.value)) + " px"
                                                color: ui.secondaryLabel
                                                font.pixelSize: ui.callout
                                                font.features: { "tnum": 1 }
                                            }
                                        }
                                        MacSlider {
                                            id: pixelSlider
                                            objectName: "pixelSize"
                                            visible: videoStyleChooser.currentIndex === 2 || videoStyleChooser.currentIndex === 3
                                            Layout.fillWidth: true
                                            from: 1; to: 16; stepSize: 1
                                            value: root.pixelSize
                                            enabled: !appearanceWriter.running
                                            Accessible.name: strings.t("appearance.pixel")
                                        }
                                        SectionLabel { text: strings.t("appearance.overlay"); Layout.topMargin: 6 }
                                        MacSegmented {
                                            id: overlayChooser
                                            objectName: "overlayStyle"
                                            Layout.fillWidth: true
                                            model: ["Default", "Coder", "Hackerman"]
                                            currentIndex: root.overlayStyles.indexOf(root.overlayStyle)
                                            enabled: !appearanceWriter.running
                                            Accessible.name: strings.t("appearance.overlay")
                                        }
                                    }
                                }
                                RowLayout {
                                    id: appearanceFooter
                                    Layout.fillWidth: true
                                    spacing: 8
                                    MacText {
                                        Layout.fillWidth: true
                                        text: root.appearanceMessage || strings.t("appearance.hint")
                                        color: root.appearanceMessage ? ui.systemRed : ui.secondaryLabel
                                        font.pixelSize: ui.callout
                                    }
                                    MacButton {
                                        objectName: "cancelStyle"
                                        text: strings.t("action.cancel")
                                        enabled: !appearanceWriter.running
                                        onClicked: root.editingAppearance = false
                                    }
                                    MacButton {
                                        objectName: "applyStyle"
                                        role: "default"
                                        text: appearanceWriter.running ? strings.t("action.applying") : strings.t("action.apply")
                                        enabled: !appearanceWriter.running
                                        onClicked: {
                                            root.appearanceMessage = ""
                                            appearanceWriter.pending = JSON.stringify({style: root.videoStyles[videoStyleChooser.currentIndex],
                                                strength: Math.round(tintSlider.value), pixelSize: Math.round(pixelSlider.value),
                                                overlay: root.overlayStyles[overlayChooser.currentIndex]})
                                            appearanceWriter.running = true
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // Camera settings, laid out like a macOS grouped form.
                    Controls.ScrollView {
                        id: settingsScroll
                        clip: true
                        enabled: !writer.running
                        opacity: popup.chromeOpacity
                        contentWidth: availableWidth
                        Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff
                        ColumnLayout {
                            id: settingsColumn
                            width: Math.min(settingsScroll.availableWidth, 640)
                            x: Math.max(0, (settingsScroll.availableWidth - width) / 2)
                            spacing: 8
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.topMargin: 4
                                Layout.bottomMargin: 6
                                MacText {
                                    Layout.fillWidth: true
                                    text: root.editingCameraId !== "" ? strings.t("settings.titleEdit") : strings.t("settings.titleNew")
                                    font.pixelSize: ui.largeTitle
                                    font.weight: Font.Bold
                                }
                                MacButton {
                                    objectName: "addCameraButton"
                                    text: strings.t("settings.add")
                                    enabled: !writer.running && root.cameras.length < 32
                                    Accessible.name: strings.t("settings.add")
                                    onClicked: root.editSettings(true)
                                }
                            }
                            SectionLabel { text: strings.t("settings.connection") }
                            FormGroup {
                                FieldRow {
                                    label: strings.t("settings.name")
                                    MacField {
                                        id: cameraName
                                        objectName: "cameraName"
                                        Layout.fillWidth: true
                                        placeholderText: strings.t("settings.namePlaceholder")
                                        maximumLength: 64
                                        Accessible.name: strings.t("settings.name")
                                    }
                                }
                                FormSeparator {}
                                FieldRow {
                                    label: strings.t("settings.url")
                                    MacField {
                                        id: address
                                        objectName: "cameraAddress"
                                        Layout.fillWidth: true
                                        text: root.config.url
                                        placeholderText: "rtsp://camera-ip:554/stream"
                                        Accessible.name: strings.t("settings.url")
                                    }
                                }
                            }
                            SectionLabel { text: strings.t("settings.auth"); Layout.topMargin: 8 }
                            FormGroup {
                                FieldRow {
                                    label: strings.t("settings.username")
                                    MacField {
                                        id: username
                                        objectName: "cameraUsername"
                                        Layout.fillWidth: true
                                        placeholderText: strings.t("settings.optional")
                                        Accessible.name: strings.t("settings.username")
                                    }
                                }
                                FormSeparator {}
                                FieldRow {
                                    label: strings.t("settings.password")
                                    MacField {
                                        id: password
                                        objectName: "cameraPassword"
                                        Layout.fillWidth: true
                                        echoMode: TextInput.Password
                                        placeholderText: strings.t("settings.optional")
                                        Accessible.name: strings.t("settings.password")
                                    }
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.topMargin: 2
                                spacing: 6
                                Text {
                                    visible: !root.message
                                    textFormat: Text.PlainText
                                    text: ui.iconLock
                                    font.family: ui.iconFont
                                    font.pixelSize: 12
                                    color: ui.tertiaryLabel
                                }
                                MacText {
                                    objectName: "settingsFootnote"
                                    Layout.fillWidth: true
                                    text: root.message || strings.t("settings.storage")
                                    color: root.message ? ui.systemRed : ui.secondaryLabel
                                    font.pixelSize: ui.caption
                                    wrapMode: Text.WordWrap
                                    elide: Text.ElideNone
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.topMargin: 10
                                spacing: 8
                                MacButton {
                                    objectName: "deleteProfile"
                                    role: "destructive"
                                    checked: root.deleteArmed
                                    text: root.deleteArmed ? strings.t("settings.confirmDelete") : strings.t("settings.delete")
                                    visible: root.editingCameraId !== ""
                                    onClicked: {
                                        if (root.deleteArmed) root.runProfileOperation({action: "delete", id: root.editingCameraId})
                                        else root.deleteArmed = true
                                    }
                                }
                                Item { Layout.fillWidth: true }
                                MacButton {
                                    objectName: "cancelProfile"
                                    text: strings.t("action.cancel")
                                    visible: root.configured
                                    onClicked: { password.text = ""; root.configuring = false }
                                }
                                MacButton {
                                    objectName: "saveProfile"
                                    role: "default"
                                    text: writer.running ? strings.t("settings.saving") : strings.t("settings.save")
                                    onClicked: root.submitProfile()
                                }
                            }
                        }
                    }
                    MotionGallery {
                        id: motionGallery
                        objectName: "motionGallery"
                        visible: root.showingMotion && !root.configuring
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        focus: root.showingMotion
                        cameraFilter: root.activeMotionFilter
                        onClosed: root.closeMotionGallery()
                        onOpenInRecordings: function(cameraId, date, time) { root.openRecordingsAt(cameraId, date, time, "motion") }
                        // Each visit fades in.
                        opacity: visible ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: Style.duration(150); easing.type: Easing.OutCubic } }
                    }
                    RecordingsView {
                        id: recordingsView
                        objectName: "recordingsView"
                        visible: root.showingRecordings && !root.configuring
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        focus: root.showingRecordings
                        active: root.showingRecordings && !root.configuring && root.opened
                        cameraId: root.selectedCameraId
                        cameraName: root.selectedCameraIndex >= 0 ? root.cameras[root.selectedCameraIndex].name : ""
                        immersive: root.fullscreen
                        onClosed: root.closeRecordings()
                        onBackRequested: { root.animateTabChange(); root.openMotionGallery(); Qt.callLater(root.refocusView) }
                        onFullscreenRequested: root.toggleFullscreen()
                        opacity: visible ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: Style.duration(150); easing.type: Easing.OutCubic } }
                    }
                }
            }
            component SectionLabel: MacText {
                color: ui.secondaryLabel
                font.pixelSize: ui.caption
                font.weight: Font.DemiBold
            }
            component FormGroup: Rectangle {
                default property alias rows: groupColumn.data
                Layout.fillWidth: true
                implicitHeight: groupColumn.implicitHeight
                radius: ui.groupRadius
                color: ui.groupFill
                border.width: 1
                border.color: ui.groupBorder
                ColumnLayout {
                    id: groupColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    spacing: 0
                }
            }
            component FormSeparator: Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: 12
                implicitHeight: 1
                color: ui.separator
            }
            component FieldRow: RowLayout {
                property alias label: rowLabel.text
                Layout.fillWidth: true
                Layout.leftMargin: 12
                Layout.rightMargin: 6
                implicitHeight: 40
                spacing: 10
                MacText {
                    id: rowLabel
                    Layout.preferredWidth: 96
                    Layout.maximumWidth: 96
                }
            }
            component MacField: Controls.TextField {
                id: field
                implicitHeight: 30
                selectByMouse: true
                leftPadding: 8
                rightPadding: 8
                font.family: ui.font
                font.pixelSize: ui.body
                color: ui.label
                placeholderTextColor: ui.tertiaryLabel
                selectionColor: ui.alpha(ui.accent, 0.55)
                selectedTextColor: ui.label
                verticalAlignment: TextInput.AlignVCenter
                background: Rectangle {
                    radius: 6
                    color: field.activeFocus ? ui.fill : "transparent"
                    border.width: field.activeFocus ? 2 : 0
                    border.color: ui.alpha(ui.accent, 0.7)
                }
            }
            // Use scene coordinates: the popup can shift as its size changes.
            // Local mouse coordinates alone would feed that shift into the drag.
            component ResizeGrip: MouseArea {
                property bool leftCorner: false
                property point dragStart
                property real startWidth: 0
                property real startHeight: 0
                width: 26
                height: 22
                anchors.bottom: parent.bottom
                hoverEnabled: true
                preventStealing: true
                cursorShape: leftCorner ? Qt.SizeBDiagCursor : Qt.SizeFDiagCursor
                acceptedButtons: Qt.LeftButton
                onPressed: function(mouse) {
                    dragStart = mapToItem(null, mouse.x, mouse.y)
                    startWidth = popup.contentWidth
                    startHeight = popup.contentHeight
                }
                onPositionChanged: function(mouse) {
                    if (!pressed) return
                    var point = mapToItem(null, mouse.x, mouse.y)
                    var width = startWidth + (leftCorner ? -1 : 1) * (point.x - dragStart.x)
                    var height = startHeight + (point.y - dragStart.y)
                    if (!root.configuring && !root.browsing) {
                        // The live view scales proportionally, like a PiP window.
                        var scale = Math.max(width / startWidth, height / startHeight)
                        width = startWidth * scale
                        height = startHeight * scale
                    }
                    root.resizeViewer(width, height)
                }
                onDoubleClicked: function() { root.resizeViewer(640, 500) }
                PanelToolTip {
                    visible: parent.containsMouse && !parent.pressed
                    text: strings.t("toolbar.resize")
                    fontSize: Style.font.caption
                }
            }
            ResizeGrip { objectName: "resizeGripLeft"; anchors.left: parent.left; leftCorner: true }
            ResizeGrip { objectName: "resizeGripRight"; anchors.right: parent.right }
        }
    }
}
