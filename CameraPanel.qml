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
    property var anchorItem: null
    property var hostWidget: null
    property bool configuring: true
    property bool showingMotion: false
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
    readonly property bool streaming: opened && !configuring && !showingMotion && configured
    readonly property bool live: primaryFeed.live
    property bool dualView: true
    property string focusedCameraId: ""
    readonly property bool dualActive: dualView && cameras.length > 1 && !focusedCameraId
    readonly property var primaryCamera: focusedCameraId
        ? cameras.find(function(camera) { return camera.id === root.focusedCameraId }) || config : config
    readonly property var secondaryCamera: cameras.find(function(camera) { return camera.id !== root.primaryCamera.id }) || ({})
    onFullscreenChanged: if (!fullscreen) focusedCameraId = ""

    function toggleDualView() {
        fullscreen = false
        focusedCameraId = ""
        dualView = !dualView
    }
    function enlargeCamera(id) {
        if (dualActive) focusedCameraId = id
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
        fullscreen = false
        configuring = false
        showingMotion = true
    }
    function closeMotionGallery() {
        showingMotion = false
    }
    function toggleFullscreen() {
        if (!configured || configuring || showingMotion) return
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
            viewMode: dualActive ? "dual" : focusedCameraId ? "focus" : "single",
            feeds: dualActive ? [primaryFeed.status(), secondaryFeed.status()] : [primaryFeed.status()]}))
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
        // Dropdowns render outside the card; don't fade chrome while one is open.
        chromeForce: cameraSelector.popup.opened || videoStyleChooser.popup.opened || overlayChooser.popup.opened
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
        // Pinned input mask is the card rect only — include open combo popups
        // so list rows that hang past the card stay clickable.
        function refreshExtraInput() {
            var combos = [cameraSelector, videoStyleChooser, overlayChooser]
            var extra = Qt.rect(0, 0, 0, 0)
            for (var i = 0; i < combos.length; i++) {
                var combo = combos[i]
                if (!combo || !combo.popup || !combo.popup.opened) continue
                var surface = combo.popup.contentItem || combo.popup
                var origin = surface.mapToItem(null, 0, 0)
                extra = Qt.rect(origin.x, origin.y, surface.width, surface.height)
                break
            }
            extraInput = extra
        }
        contentWidth: root.fullscreen
            ? popup.availableCardWidth
            : fittedContentWidth(root.viewerWidth)
        contentHeight: root.fullscreen
            ? popup.availableCardHeight
            : cappedContentHeight(root.viewerHeight)
        focusTarget: content

        FocusScope {
            id: content
            anchors.fill: parent
            Keys.onEscapePressed: function(event) {
                if (root.exitFullscreenIfActive(event)) return
                if (root.showingMotion) {
                    root.closeMotionGallery()
                    event.accepted = true
                    return
                }
                root.close()
            }
            ColumnLayout {
                anchors.fill: parent
                anchors.bottomMargin: 16
                spacing: 10
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
                            text: "Drag to move camera"
                            fontSize: Style.font.caption
                        }
                    }
                    RowLayout {
                        id: headerControls
                        anchors.fill: parent
                        Controls.ComboBox {
                            id: cameraSelector
                            objectName: "cameraSelector"
                            Layout.fillWidth: true
                            Layout.preferredWidth: Math.min(240, headerControls.width * 0.5)
                            Layout.maximumWidth: Math.min(240, headerControls.width * 0.5)
                            implicitHeight: 32
                            model: root.cameras
                            textRole: "name"
                            currentIndex: root.selectedCameraIndex
                            displayText: root.cameras.length ? currentText : "No cameras"
                            enabled: !writer.running && root.cameras.length > 0 && !root.showingMotion
                            Accessible.name: "Select camera"
                            onActivated: function(index) { root.selectCamera(index) }
                            contentItem: Text {
                                textFormat: Text.PlainText
                                text: cameraSelector.displayText
                                color: Commons.Color.popups.text
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                verticalAlignment: Text.AlignVCenter
                                elide: Text.ElideRight
                                leftPadding: 10
                                rightPadding: 28
                            }
                            background: Rectangle {
                                radius: 10
                                color: Commons.Color.popups.background
                                border.width: 1
                                border.color: cameraSelector.activeFocus
                                    ? Commons.Color.accent
                                    : Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.5)
                            }
                            indicator: Text {
                                x: cameraSelector.width - width - 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: "\u2304"
                                color: Commons.Color.popups.text
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                            }
                            delegate: Controls.ItemDelegate {
                                required property var modelData
                                width: cameraSelector.popup.availableWidth
                                height: 36
                                text: modelData.name
                                contentItem: Text {
                                    textFormat: Text.PlainText
                                    text: parent.text
                                    color: parent.highlighted ? Style.hoverStateColor(Commons.Color.popups.text, Commons.Color.accent) : Commons.Color.popups.text
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.body
                                    elide: Text.ElideRight
                                    verticalAlignment: Text.AlignVCenter
                                    leftPadding: 10
                                    rightPadding: 10
                                }
                                background: Rectangle {
                                    radius: 8
                                    color: parent.hovered || parent.highlighted
                                        ? Style.hoverFillFor(Commons.Color.popups.text, Commons.Color.accent)
                                        : "transparent"
                                }
                                PointerArea {}
                            }
                            popup: Controls.Popup {
                                y: cameraSelector.height + 6
                                width: cameraSelector.width + 12
                                height: Math.min(220, cameraList.contentHeight + 12)
                                padding: 6
                                focus: true
                                contentItem: ListView {
                                    id: cameraList
                                    clip: true
                                    spacing: 2
                                    boundsBehavior: Flickable.StopAtBounds
                                    model: cameraSelector.popup.visible ? cameraSelector.delegateModel : null
                                    currentIndex: cameraSelector.highlightedIndex
                                    Controls.ScrollIndicator.vertical: Controls.ScrollIndicator {}
                                }
                                background: Rectangle {
                                    radius: 12
                                    color: Commons.Color.popups.background
                                    border.width: 1
                                    border.color: Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.65)
                                }
                            }
                            PointerArea {}
                        }
                        Item {
                            objectName: "headerDragSpace"
                            Layout.fillWidth: true
                            Layout.minimumWidth: 16
                            Layout.fillHeight: true
                        }
                        Controls.Button {
                            objectName: "motionButton"
                            text: root.showingMotion ? "Live" : headerControls.width < 540 ? "▧" : "Motion"
                            leftPadding: 12
                            rightPadding: 12
                            topPadding: 7
                            bottomPadding: 7
                            hoverEnabled: true
                            Accessible.name: root.showingMotion ? "Back to live camera" : "Motion captures"
                            PanelToolTip {
                                visible: parent.hovered
                                text: root.showingMotion
                                    ? "Return to live view"
                                    : "Motion stills from the last 24 hours"
                                fontSize: Style.font.caption
                            }
                            enabled: !writer.running && root.configured
                            background: Rectangle {
                                radius: height / 2
                                color: parent.hovered
                                    ? Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.12)
                                    : Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.06)
                                border.width: 1
                                border.color: Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.5)
                            }
                            contentItem: Text {
                                text: parent.text
                                color: parent.hovered ? Commons.Color.accent : Commons.Color.popups.text
                                font.pixelSize: Style.font.caption
                                font.weight: Font.DemiBold
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                            onClicked: {
                                if (root.showingMotion) root.closeMotionGallery()
                                else root.openMotionGallery()
                            }
                            PointerArea {}
                        }
                        Controls.Button {
                            objectName: "dualViewButton"
                            text: headerControls.width < 540 ? "◫" : strings.t("layout.dual")
                            leftPadding: 12
                            rightPadding: 12
                            topPadding: 7
                            bottomPadding: 7
                            hoverEnabled: true
                            visible: !root.configuring && !root.showingMotion
                            enabled: root.cameras.length > 1
                            checkable: true
                            checked: root.dualView
                            Accessible.name: strings.t("layout.twoCameras")
                            PanelToolTip {
                                visible: parent.hovered
                                text: root.dualView ? strings.t("layout.showSingle") : strings.t("layout.showBoth")
                                fontSize: Style.font.caption
                            }
                            background: Rectangle {
                                radius: height / 2
                                color: parent.hovered
                                    ? Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.12)
                                    : Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.06)
                                border.width: 1
                                border.color: Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.5)
                            }
                            contentItem: Text {
                                text: parent.text
                                color: parent.hovered || parent.checked ? Commons.Color.accent : Commons.Color.popups.text
                                font.pixelSize: Style.font.caption
                                font.weight: Font.DemiBold
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                            onClicked: root.toggleDualView()
                            PointerArea {}
                        }
                        Controls.Button {
                            objectName: "themeButton"
                            text: headerControls.width < 540 ? "◐" : "Themes"
                            leftPadding: 12
                            rightPadding: 12
                            topPadding: 7
                            bottomPadding: 7
                            hoverEnabled: true
                            visible: !root.configuring && !root.showingMotion
                            Accessible.name: "Video themes"
                            PanelToolTip {
                                visible: parent.hovered
                                text: "Video style picker"
                                fontSize: Style.font.caption
                            }
                            background: Rectangle {
                                radius: height / 2
                                color: parent.hovered
                                    ? Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.12)
                                    : Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.06)
                                border.width: 1
                                border.color: Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.5)
                            }
                            contentItem: Text {
                                text: parent.text
                                color: parent.hovered ? Commons.Color.accent : Commons.Color.popups.text
                                font.pixelSize: Style.font.caption
                                font.weight: Font.DemiBold
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                            onClicked: root.toggleAppearance()
                            PointerArea {}
                        }
                        Controls.Button {
                            objectName: "configButton"
                            text: headerControls.width < 540 ? "⚙" : "Config"
                            leftPadding: 12
                            rightPadding: 12
                            topPadding: 7
                            bottomPadding: 7
                            hoverEnabled: true
                            Accessible.name: "Camera settings"
                            PanelToolTip {
                                visible: parent.hovered
                                text: "Connection settings"
                                fontSize: Style.font.caption
                            }
                            enabled: !writer.running
                            background: Rectangle {
                                radius: height / 2
                                color: parent.hovered
                                    ? Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.12)
                                    : Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.06)
                                border.width: 1
                                border.color: Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.5)
                            }
                            contentItem: Text {
                                text: parent.text
                                color: parent.hovered ? Commons.Color.accent : Commons.Color.popups.text
                                font.pixelSize: Style.font.caption
                                font.weight: Font.DemiBold
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                            onClicked: root.editSettings()
                            PointerArea {}
                        }
                        Controls.Switch {
                            id: pinSwitch
                            objectName: "pinSwitch"
                            visible: !root.showingMotion
                            implicitWidth: 44
                            implicitHeight: 28
                            padding: 0
                            checked: root.pinned
                            hoverEnabled: true
                            Accessible.name: root.pinned ? "Unpin camera" : "Keep camera above other windows"
                            PanelToolTip {
                                visible: pinSwitch.hovered
                                text: pinSwitch.checked ? "Return to popup mode" : "Stay visible while using other windows"
                                fontSize: Style.font.caption
                            }
                            onClicked: root.pinned = checked
                            indicator: Rectangle {
                                x: 0
                                y: (pinSwitch.height - height) / 2
                                width: 44
                                height: 24
                                radius: height / 2
                                color: pinSwitch.hovered
                                    ? Style.hoverFillFor(Commons.Color.popups.text, Commons.Color.accent)
                                    : pinSwitch.checked
                                        ? Style.selectedFillFor(Commons.Color.popups.text, Commons.Color.accent)
                                        : Style.normalFillFor(Commons.Color.popups.text, Commons.Color.accent)
                                border.width: pinSwitch.activeFocus ? 2 : 1
                                border.color: pinSwitch.activeFocus ? Commons.Color.accent : Commons.Color.popups.border
                                Rectangle {
                                    x: pinSwitch.checked ? parent.width - width - 3 : 3
                                    y: 3
                                    width: 18
                                    height: 18
                                    radius: height / 2
                                    color: pinSwitch.checked
                                        ? Style.selectedStateColor(Commons.Color.popups.text, Commons.Color.accent)
                                        : Qt.darker(Commons.Color.popups.text, 1.25)
                                    Behavior on x {
                                        NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic }
                                    }
                                }
                            }
                            contentItem: Item {}
                            PointerArea {}
                        }
                        ToolButton {
                            text: "×"
                            hoverEnabled: true
                            implicitWidth: 32
                            implicitHeight: 32
                            padding: 0
                            Accessible.name: "Close camera"
                            contentItem: Text {
                                text: parent.text
                                color: parent.hovered ? Commons.Color.accent : Commons.Color.popups.text
                                font.family: Style.font.family
                                font.pixelSize: Style.font.body
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                            background: Rectangle {
                                radius: height / 2
                                color: parent.hovered
                                    ? Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.12)
                                    : "transparent"
                                border.width: parent.hovered ? 1 : 0
                                border.color: Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.5)
                            }
                            PointerArea {}
                            onClicked: root.close()
                        }
                    }
                }
                StackLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    currentIndex: root.configuring ? 1 : root.showingMotion ? 2 : 0
                    ColumnLayout {
                        id: viewerPage
                        spacing: 8
                        GridLayout {
                            id: feedGrid
                            objectName: "feedGrid"
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.minimumHeight: root.dualActive && columns === 1 ? 240 : 120
                            columns: root.dualActive && width >= 720 ? 2 : 1
                            columnSpacing: 10
                            rowSpacing: 10
                            CameraFeed {
                                id: primaryFeed
                                objectName: "primaryFeed"
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                Layout.preferredWidth: 1
                                Layout.preferredHeight: 1
                                camera: root.primaryCamera
                                streaming: root.streaming
                                compact: root.dualActive
                                fullscreen: root.fullscreen
                                videoStyle: root.editingAppearance ? root.videoStyles[videoStyleChooser.currentIndex] : root.videoStyle
                                tintStrength: root.editingAppearance ? tintSlider.value : root.tintStrength
                                pixelSize: root.editingAppearance ? Math.round(pixelSlider.value) : root.pixelSize
                                overlayStyle: root.editingAppearance ? root.overlayStyles[overlayChooser.currentIndex] : root.overlayStyle
                                message: root.message || root.sizeSaveError || root.positionSaveError
                                onAudioRequested: root.toggleFeedAudio(primaryFeed)
                                onFullscreenRequested: root.enlargeCamera(camera.id || "")
                            }
                            CameraFeed {
                                id: secondaryFeed
                                objectName: "secondaryFeed"
                                visible: root.dualActive
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                Layout.preferredWidth: 1
                                Layout.preferredHeight: 1
                                camera: root.secondaryCamera
                                streaming: root.streaming && root.dualActive
                                compact: true
                                videoStyle: primaryFeed.videoStyle
                                tintStrength: primaryFeed.tintStrength
                                pixelSize: primaryFeed.pixelSize
                                overlayStyle: primaryFeed.overlayStyle
                                onAudioRequested: root.toggleFeedAudio(secondaryFeed)
                                onFullscreenRequested: root.enlargeCamera(camera.id || "")
                            }
                        }
                        Rectangle {
                            id: themeEditor
                            objectName: "themeEditor"
                            visible: root.editingAppearance
                            Layout.fillWidth: true
                            Layout.preferredHeight: Math.min(appearanceColumn.implicitHeight + appearanceFooter.implicitHeight + 36, viewerPage.height * 0.6)
                            radius: 12
                            color: Commons.Color.popups.background
                            border.width: 1
                            border.color: Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.65)
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 12
                                spacing: 12
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
                                        spacing: 12
                                        Label {
                                            text: "Video style · all cameras"
                                            color: root.foreground
                                            font.family: Style.font.family
                                            font.pixelSize: Style.font.caption
                                            font.weight: Font.Medium
                                        }
                                        Controls.ComboBox {
                                            id: videoStyleChooser
                                            objectName: "videoStyle"
                                            Layout.fillWidth: true
                                            model: ["Original", "Omarchy", "Pixel", "Omarchy Pixel"]
                                            currentIndex: root.videoStyles.indexOf(root.videoStyle)
                                            enabled: !appearanceWriter.running
                                            Accessible.name: "Video style"
                                            implicitHeight: 32
                                            contentItem: Text {
                                                text: videoStyleChooser.displayText
                                                color: Commons.Color.popups.text
                                                font.family: Style.font.family
                                                font.pixelSize: Style.font.caption
                                                verticalAlignment: Text.AlignVCenter
                                                leftPadding: 10; rightPadding: 28
                                            }
                                            background: Rectangle {
                                                radius: 10
                                                color: Commons.Color.popups.background
                                                border.width: 1
                                                border.color: videoStyleChooser.activeFocus
                                                    ? Commons.Color.accent
                                                    : Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.5)
                                            }
                                            indicator: Text {
                                                x: videoStyleChooser.width - width - 10
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: "\u2304"
                                                color: Commons.Color.popups.text
                                                font.family: Style.font.family
                                                font.pixelSize: Style.font.caption
                                            }
                                            delegate: Controls.ItemDelegate {
                                                required property string modelData
                                                required property int index
                                                width: videoStyleChooser.popup.availableWidth
                                                height: 36
                                                text: modelData
                                                highlighted: videoStyleChooser.highlightedIndex === index
                                                contentItem: Text {
                                                    text: parent.text
                                                    color: parent.highlighted
                                                        ? Style.hoverStateColor(Commons.Color.popups.text, Commons.Color.accent)
                                                        : Commons.Color.popups.text
                                                    font.family: Style.font.family
                                                    font.pixelSize: Style.font.body
                                                    verticalAlignment: Text.AlignVCenter
                                                    leftPadding: 10
                                                    rightPadding: 10
                                                }
                                                background: Rectangle {
                                                    radius: 8
                                                    color: parent.hovered || parent.highlighted
                                                        ? Style.hoverFillFor(Commons.Color.popups.text, Commons.Color.accent)
                                                        : "transparent"
                                                }
                                                PointerArea {}
                                            }
                                            popup: Controls.Popup {
                                                y: videoStyleChooser.height + 6
                                                width: videoStyleChooser.width + 12
                                                implicitHeight: styleList.contentHeight + 12
                                                padding: 6
                                                focus: true
                                                contentItem: ListView {
                                                    id: styleList
                                                    clip: true
                                                    spacing: 2
                                                    boundsBehavior: Flickable.StopAtBounds
                                                    implicitHeight: contentHeight
                                                    model: videoStyleChooser.popup.visible ? videoStyleChooser.delegateModel : null
                                                    currentIndex: videoStyleChooser.highlightedIndex
                                                }
                                                background: Rectangle {
                                                    radius: 12
                                                    color: Commons.Color.popups.background
                                                    border.width: 1
                                                    border.color: Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.65)
                                                }
                                            }
                                            PointerArea {}
                                        }
                                        RowLayout {
                                            visible: videoStyleChooser.currentIndex === 1 || videoStyleChooser.currentIndex === 3
                                            Layout.fillWidth: true
                                            Label {
                                                text: "Tint strength"
                                                color: root.foreground
                                                font.family: Style.font.family
                                                font.pixelSize: Style.font.caption
                                                font.weight: Font.Medium
                                            }
                                            Controls.Slider {
                                                id: tintSlider
                                                objectName: "tintStrength"
                                                Layout.fillWidth: true
                                                from: 0; to: 100; stepSize: 1
                                                value: root.tintStrength
                                                enabled: !appearanceWriter.running
                                                Accessible.name: "Tint strength"
                                                background: Rectangle {
                                                    x: tintSlider.leftPadding
                                                    y: tintSlider.topPadding + tintSlider.availableHeight / 2 - height / 2
                                                    width: tintSlider.availableWidth; height: 4
                                                    color: Commons.Color.popups.border
                                                    Rectangle { width: tintSlider.visualPosition * parent.width; height: parent.height; color: Commons.Color.accent }
                                                }
                                                handle: Rectangle {
                                                    x: tintSlider.leftPadding + tintSlider.visualPosition * (tintSlider.availableWidth - width)
                                                    y: tintSlider.topPadding + tintSlider.availableHeight / 2 - height / 2
                                                    implicitWidth: 14; implicitHeight: 18
                                                    color: tintSlider.pressed ? Commons.Color.popups.text : Commons.Color.accent
                                                    border.width: tintSlider.activeFocus ? 2 : 1
                                                    border.color: Commons.Color.popups.text
                                                }
                                                PointerArea {}
                                            }
                                            Label {
                                                text: Math.round(tintSlider.value) + "%"
                                                color: root.foreground
                                                font.family: Style.font.family
                                                font.pixelSize: Style.font.caption
                                            }
                                        }
                                        RowLayout {
                                            visible: videoStyleChooser.currentIndex === 2 || videoStyleChooser.currentIndex === 3
                                            Layout.fillWidth: true
                                            Label {
                                                text: "Pixel size"
                                                color: root.foreground
                                                font.family: Style.font.family
                                                font.pixelSize: Style.font.caption
                                                font.weight: Font.Medium
                                            }
                                            Controls.Slider {
                                                id: pixelSlider
                                                objectName: "pixelSize"
                                                Layout.fillWidth: true
                                                from: 1; to: 16; stepSize: 1
                                                value: root.pixelSize
                                                enabled: !appearanceWriter.running
                                                Accessible.name: "Pixel size"
                                                PanelToolTip {
                                                    visible: parent.hovered
                                                    text: "Stronger pixel blocks"
                                                    fontSize: Style.font.caption
                                                }
                                                background: Rectangle {
                                                    x: pixelSlider.leftPadding
                                                    y: pixelSlider.topPadding + pixelSlider.availableHeight / 2 - height / 2
                                                    width: pixelSlider.availableWidth; height: 4
                                                    color: Commons.Color.popups.border
                                                    Rectangle { width: pixelSlider.visualPosition * parent.width; height: parent.height; color: Commons.Color.accent }
                                                }
                                                handle: Rectangle {
                                                    x: pixelSlider.leftPadding + pixelSlider.visualPosition * (pixelSlider.availableWidth - width)
                                                    y: pixelSlider.topPadding + pixelSlider.availableHeight / 2 - height / 2
                                                    implicitWidth: 14; implicitHeight: 18
                                                    color: pixelSlider.pressed ? Commons.Color.popups.text : Commons.Color.accent
                                                    border.width: pixelSlider.activeFocus ? 2 : 1
                                                    border.color: Commons.Color.popups.text
                                                }
                                                PointerArea {}
                                            }
                                            Label {
                                                text: Math.round(pixelSlider.value) + " px"
                                                color: root.foreground
                                                font.family: Style.font.family
                                                font.pixelSize: Style.font.caption
                                            }
                                        }
                                        RowLayout {
                                            Layout.fillWidth: true
                                            Label {
                                            text: "Overlay"
                                            color: root.foreground
                                            font.family: Style.font.family
                                            font.pixelSize: Style.font.caption
                                            font.weight: Font.Medium
                                        }
                                            Controls.ComboBox {
                                                id: overlayChooser
                                                objectName: "overlayStyle"
                                                Layout.fillWidth: true
                                                model: ["Default", "Coder", "Hackerman"]
                                                currentIndex: root.overlayStyles.indexOf(root.overlayStyle)
                                                enabled: !appearanceWriter.running
                                                Accessible.name: "Camera overlay"
                                                implicitHeight: 32
                                                contentItem: Text {
                                                    text: overlayChooser.displayText
                                                    color: Commons.Color.popups.text
                                                    font.family: Style.font.family
                                                    font.pixelSize: Style.font.caption
                                                    verticalAlignment: Text.AlignVCenter
                                                    leftPadding: 10; rightPadding: 28
                                                }
                                                background: Rectangle {
                                                    radius: 10
                                                    color: Commons.Color.popups.background
                                                    border.width: 1
                                                    border.color: overlayChooser.activeFocus
                                                        ? Commons.Color.accent
                                                        : Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.5)
                                                }
                                                indicator: Text {
                                                    x: overlayChooser.width - width - 10
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: "\u2304"
                                                    color: Commons.Color.popups.text
                                                    font.family: Style.font.family
                                                    font.pixelSize: Style.font.caption
                                                }
                                                delegate: Controls.ItemDelegate {
                                                    required property string modelData
                                                    required property int index
                                                    width: overlayChooser.popup.availableWidth
                                                    height: 36
                                                    text: modelData
                                                    highlighted: overlayChooser.highlightedIndex === index
                                                    contentItem: Text {
                                                        text: parent.text
                                                        color: parent.highlighted
                                                            ? Style.hoverStateColor(Commons.Color.popups.text, Commons.Color.accent)
                                                            : Commons.Color.popups.text
                                                        font.family: Style.font.family
                                                        font.pixelSize: Style.font.body
                                                        verticalAlignment: Text.AlignVCenter
                                                        leftPadding: 10
                                                        rightPadding: 10
                                                    }
                                                    background: Rectangle {
                                                        radius: 8
                                                        color: parent.hovered || parent.highlighted
                                                            ? Style.hoverFillFor(Commons.Color.popups.text, Commons.Color.accent)
                                                            : "transparent"
                                                    }
                                                    PointerArea {}
                                                }
                                                popup: Controls.Popup {
                                                    y: overlayChooser.height + 6
                                                    width: overlayChooser.width + 12
                                                    implicitHeight: overlayList.contentHeight + 12
                                                    padding: 6
                                                    focus: true
                                                    contentItem: ListView {
                                                        id: overlayList
                                                        clip: true
                                                        spacing: 2
                                                        boundsBehavior: Flickable.StopAtBounds
                                                        implicitHeight: contentHeight
                                                        model: overlayChooser.popup.visible ? overlayChooser.delegateModel : null
                                                        currentIndex: overlayChooser.highlightedIndex
                                                    }
                                                    background: Rectangle {
                                                        radius: 12
                                                        color: Commons.Color.popups.background
                                                        border.width: 1
                                                        border.color: Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.65)
                                                    }
                                                }
                                                PointerArea {}
                                            }
                                        }

                                    }
                                }
                                RowLayout {
                                    id: appearanceFooter
                                    Layout.fillWidth: true
                                    Label {
                                        text: root.appearanceMessage || "Previewing live · Apply to save for all cameras."
                                        color: root.foreground
                                        font.family: Style.font.family
                                        font.pixelSize: Style.font.caption
                                        wrapMode: Text.WordWrap
                                        Layout.fillWidth: true
                                    }
                                Controls.Button {
                                    objectName: "applyStyle"
                                    text: appearanceWriter.running ? "Applying…" : "Apply"
                                    hoverEnabled: true
                                    leftPadding: 16
                                    rightPadding: 16
                                    topPadding: 7
                                    bottomPadding: 7
                                    enabled: !appearanceWriter.running
                                    background: Rectangle {
                                        radius: height / 2
                                        color: parent.hovered
                                            ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.35)
                                            : Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.18)
                                        border.width: 1
                                        border.color: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.55)
                                    }
                                    contentItem: Text {
                                        text: parent.text
                                        color: Commons.Color.accent
                                        font.pixelSize: Style.font.caption
                                        font.weight: Font.DemiBold
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                    onClicked: {
                                        root.appearanceMessage = ""
                                        appearanceWriter.pending = JSON.stringify({style: root.videoStyles[videoStyleChooser.currentIndex],
                                            strength: Math.round(tintSlider.value), pixelSize: Math.round(pixelSlider.value),
                                            overlay: root.overlayStyles[overlayChooser.currentIndex]})
                                        appearanceWriter.running = true
                                    }
                                    PointerArea {}
                                }
                                }
                            }
                        }
                    }
                    Controls.ScrollView {
                        id: settingsScroll
                        clip: true
                        enabled: !writer.running
                        opacity: popup.chromeOpacity
                        contentWidth: availableWidth
                        Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff
                        ColumnLayout {
                            width: settingsScroll.availableWidth
                            spacing: 8
                            RowLayout {
                                Layout.fillWidth: true
                                Label { text: "Camera name"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.weight: Font.Medium; Layout.fillWidth: true }
                                Controls.Button {
                                    objectName: "addCameraButton"
                                    text: "+"
                                    leftPadding: 12
                                    rightPadding: 12
                                    topPadding: 4
                                    bottomPadding: 4
                                    hoverEnabled: true
                                    background: Rectangle {
                                        radius: height / 2
                                        color: parent.hovered
                                            ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.28)
                                            : Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.08)
                                        border.width: 1
                                        border.color: Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.5)
                                    }
                                    contentItem: Text {
                                        text: parent.text
                                        color: parent.hovered ? Commons.Color.accent : Commons.Color.popups.text
                                        font.pixelSize: 18
                                        font.weight: Font.DemiBold
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                    enabled: !writer.running && root.cameras.length < 32
                                    Accessible.name: "Add camera"
                                    PanelToolTip {
                                        visible: parent.hovered
                                        text: "Add camera"
                                        fontSize: Style.font.caption
                                    }
                                    onClicked: root.editSettings(true)
                                    PointerArea {}
                                }
                            }
                            TextField {
                                id: cameraName
                                objectName: "cameraName"
                                Layout.fillWidth: true
                                placeholderText: "Front door"
                                maximumLength: 64
                                selectByMouse: true
                                Accessible.name: "Camera name"
                                background: Rectangle {
                                    radius: 10
                                    color: Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.05)
                                    border.width: 1
                                    border.color: cameraName.activeFocus
                                        ? Commons.Color.accent
                                        : Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.5)
                                }
                            }
                            Label { text: "RTSP address"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.weight: Font.Medium }
                            TextField {
                                id: address
                                objectName: "cameraAddress"
                                Layout.fillWidth: true
                                text: root.config.url
                                placeholderText: "rtsp://camera-ip:554/stream"
                                selectByMouse: true
                                Accessible.name: "RTSP address"
                                background: Rectangle {
                                    radius: 10
                                    color: Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.05)
                                    border.width: 1
                                    border.color: address.activeFocus
                                        ? Commons.Color.accent
                                        : Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.5)
                                }
                            }
                            Label { text: "Username"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.weight: Font.Medium }
                            TextField {
                                id: username
                                objectName: "cameraUsername"
                                Layout.fillWidth: true
                                selectByMouse: true
                                Accessible.name: "Username"
                                background: Rectangle {
                                    radius: 10
                                    color: Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.05)
                                    border.width: 1
                                    border.color: username.activeFocus
                                        ? Commons.Color.accent
                                        : Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.5)
                                }
                            }
                            Label { text: "Password"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.weight: Font.Medium }
                            TextField {
                                id: password
                                objectName: "cameraPassword"
                                Layout.fillWidth: true
                                echoMode: TextInput.Password
                                selectByMouse: true
                                Accessible.name: "Password"
                                background: Rectangle {
                                    radius: 10
                                    color: Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.05)
                                    border.width: 1
                                    border.color: password.activeFocus
                                        ? Commons.Color.accent
                                        : Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.5)
                                }
                            }
                            Label {
                                text: root.message || "Saved locally in a file readable only by your user account."
                                color: root.message ? "#f38ba8" : root.foreground
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Controls.Button {
                                    text: root.deleteArmed ? "Confirm delete" : "Delete"
                                    hoverEnabled: true
                                    leftPadding: 14
                                    rightPadding: 14
                                    topPadding: 7
                                    bottomPadding: 7
                                    visible: root.editingCameraId !== ""
                                    background: Rectangle {
                                        radius: height / 2
                                        color: parent.hovered
                                            ? Qt.rgba(0.9, 0.3, 0.35, 0.35)
                                            : Qt.rgba(0.9, 0.3, 0.35, 0.15)
                                        border.width: 1
                                        border.color: Qt.rgba(0.9, 0.3, 0.35, 0.55)
                                    }
                                    contentItem: Text {
                                        text: parent.text
                                        color: parent.hovered ? "#ffb4b8" : "#f38ba8"
                                        font.pixelSize: Style.font.caption
                                        font.weight: Font.Medium
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                    onClicked: {
                                        if (root.deleteArmed) root.runProfileOperation({action: "delete", id: root.editingCameraId})
                                        else root.deleteArmed = true
                                    }
                                    PointerArea {}
                                }
                                Item { Layout.fillWidth: true }
                                Controls.Button {
                                    text: "Cancel"
                                    hoverEnabled: true
                                    leftPadding: 14
                                    rightPadding: 14
                                    topPadding: 7
                                    bottomPadding: 7
                                    visible: root.configured
                                    background: Rectangle {
                                        radius: height / 2
                                        color: parent.hovered
                                            ? Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.12)
                                            : Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.06)
                                        border.width: 1
                                        border.color: Qt.rgba(Commons.Color.popups.border.r, Commons.Color.popups.border.g, Commons.Color.popups.border.b, 0.5)
                                    }
                                    contentItem: Text {
                                        text: parent.text
                                        color: parent.hovered ? Commons.Color.accent : Commons.Color.popups.text
                                        font.pixelSize: Style.font.caption
                                        font.weight: Font.Medium
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                    onClicked: { password.text = ""; root.configuring = false }
                                    PointerArea {}
                                }
                                Controls.Button {
                                    objectName: "saveProfile"
                                    text: writer.running ? "Saving…" : "Save & connect"
                                    hoverEnabled: true
                                    leftPadding: 16
                                    rightPadding: 16
                                    topPadding: 7
                                    bottomPadding: 7
                                    background: Rectangle {
                                        radius: height / 2
                                        color: parent.hovered
                                            ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.4)
                                            : Commons.Color.accent
                                        border.width: 0
                                    }
                                    contentItem: Text {
                                        text: parent.text
                                        color: parent.hovered ? "#ffffff" : Qt.darker(Commons.Color.accent, 1.8)
                                        font.pixelSize: Style.font.caption
                                        font.weight: Font.DemiBold
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                    onClicked: root.submitProfile()
                                    PointerArea {}
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
                        onClosed: root.closeMotionGallery()
                    }
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
                    root.resizeViewer(startWidth + (leftCorner ? -1 : 1) * (point.x - dragStart.x),
                        startHeight + (point.y - dragStart.y))
                }
                onDoubleClicked: function() { root.resizeViewer(640, 500) }
                PanelToolTip {
                    visible: parent.containsMouse && !parent.pressed
                    text: "Drag to resize"
                    fontSize: Style.font.caption
                }
            }
            ResizeGrip { anchors.left: parent.left; leftCorner: true }
            ResizeGrip { anchors.right: parent.right }
        }
    }
}
