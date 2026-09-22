import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import qs.Commons
import "Camera"
ShellRoot {
    PanelWindow {
        id: effectWindow
        visible: false
        implicitWidth: 360
        implicitHeight: 180
        exclusionMode: ExclusionMode.Ignore
        Item {
            id: fixture
            anchors.fill: parent
            Rectangle {
                id: gradientSource
                anchors.fill: parent
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: "black" }
                    GradientStop { position: 1; color: "white" }
                }
            }
            VideoEffect { id: fixtureEffect; anchors.fill: parent; sourceItem: gradientSource }
            VideoOverlay { id: fixtureOverlay; active: false; anchors.fill: parent; cameraName: "Test camera" }
            Rectangle { x: 20; y: 20; width: 1; height: 20; color: "red" }
        }
        AudioWaveform { id: fixtureWave; visible: false; x: 230; y: 18 }
    }
    FileView { id: processStats; path: "/proc/" + Quickshell.processId + "/stat"; blockLoading: true }
    PanelWindow {
        id: barWindow
        anchors { top: true; left: true; right: true }
        implicitHeight: 28
        Item { id: anchor; x: 700; width: 30; height: 28 }
    }
    QtObject {
        id: fakeBar
        property string position: "top"
        property int barSize: 28
        property color foreground: "white"
        property color barForeground: "white"
        property var activePopout: null
        function requestPopout(key) { activePopout = key }
        function releasePopout(key) { activePopout = null }
    }
    CameraPanel { id: panel; bar: fakeBar; anchorItem: anchor }
    Component { id: newPanel; CameraPanel { bar: fakeBar; anchorItem: anchor } }
    Timer {
        interval: 1000; running: true
        onTriggered: {
            try {
                if (Quickshell.env("CAMERA_TEST_BENCHMARK") === "1") probe.runVideoStyles(true)
                else {
                    probe.runAppearance(); probe.runOverlayPixels(); probe.runEffectPixels(); probe.runDrag()
                    if (Quickshell.env("CAMERA_TEST_UI_ONLY") !== "1") { probe.runVideoStyles(false); probe.runReconnect() }
                    probe.runProfiles()
                }
                console.log("CAMERA_CHECKS_PASSED")
            }
            catch (error) { console.error("CAMERA_CHECKS_FAILED", error, error.stack) }
            finally { panel.close(); Qt.quit() }
        }
    }
    TestCase {
        id: probe
        optional: true
        name: "CameraDrag"
        when: false
        function assertOk(value, message) {
            if (!value) throw new Error(message || "Assertion failed")
        }
        function equal(actual, expected, message) {
            if (actual !== expected) throw new Error((message || "Comparison failed") + ": " + actual + " != " + expected)
        }
        function sameResampledImage(actual, expected) {
            if (actual.width !== expected.width || actual.height !== expected.height) return false
            // Fractional monitor scales resample the capture texture. Allow two
            // channel levels of rounding, while still catching a changed filter.
            for (var y = 0; y < actual.height; y += Math.max(1, Math.floor(actual.height / 24))) {
                for (var x = 0; x < actual.width; x += Math.max(1, Math.floor(actual.width / 48))) {
                    if (Math.abs(actual.red(x,y) - expected.red(x,y)) > 2
                        || Math.abs(actual.green(x,y) - expected.green(x,y)) > 2
                        || Math.abs(actual.blue(x,y) - expected.blue(x,y)) > 2
                        || Math.abs(actual.alpha(x,y) - expected.alpha(x,y)) > 2) return false
                }
            }
            return true
        }
        function eventually(predicate, timeout) {
            var deadline = Date.now() + timeout
            while (!predicate() && Date.now() < deadline) wait(25)
            assertOk(predicate(), "Timed out; playback status: " + panel.playbackStatus())
        }
        function find(item, predicate) {
            if (predicate(item)) return item
            var children = item.data || item.children || []
            for (var i = 0; i < children.length; ++i) {
                var result = find(children[i], predicate)
                if (result) return result
            }
            return null
        }
        function capture(item, name) {
            var directory = Quickshell.env("CAMERA_TEST_CAPTURE_DIR")
            if (!directory) return
            var complete = false
            assertOk(item.grabToImage(function(result) {
                assertOk(result.saveToFile(directory + "/" + name + ".png"), "save visual capture")
                complete = true
            }), "request visual capture")
            eventually(function() { return complete }, 2000)
        }
        function runProfiles() {
            panel.open()
            panel.editSettings(true)
            var popup = find(panel, function(i) { return i.cardOrigin !== undefined })
            var content = popup.contentItem[0]
            function field(name) { return find(content, function(i) { return i.objectName === name }) }
            field("cameraName").text = "Front door"
            field("cameraAddress").text = "rtsp://127.0.0.1:1/front"
            field("cameraUsername").text = "test-user"
            field("cameraPassword").text = "test-password"
            panel.submitProfile()
            eventually(function() { return panel.cameras.length === 1 && !panel.configuring }, 4000)
            var offlineOverlay = field("videoOverlay")
            assertOk(offlineOverlay.item !== null && offlineOverlay.width > 0 && offlineOverlay.height > 0,
                "offline feed displays corner borders before its first video frame")
            equal(find(offlineOverlay.item, function(i) { return i.objectName === "overlayCorner" }).color.toString(),
                "#ff4545", "offline camera shows red corner borders")
            capture(content, "offline-feed")
            var firstId = panel.selectedCameraId
            panel.editSettings(true)
            equal(field("cameraUsername").text, "", "new camera does not inherit credentials")
            field("cameraName").text = "Garage"
            field("cameraAddress").text = "rtsp://127.0.0.1:1/garage"
            panel.submitProfile()
            eventually(function() { return panel.cameras.length === 2 && !panel.configuring }, 4000)
            var secondId = panel.selectedCameraId
            equal(panel.config.url, "rtsp://127.0.0.1:1/garage", "new camera selected")
            var selector = field("cameraSelector")
            assertOk(field("nextCameraButton") === null && field("cameraTitle") === null,
                "standalone camera title and next button removed")
            assertOk(selector.visible && !field("addCameraButton").visible, "main header shows selector without add button")
            equal(selector.displayText, "Garage", "header selector shows current camera")
            panel.pinned = true
            mouseMove(selector, 20, selector.height / 2)
            wait(250)
            mouseClick(selector)
            wait(100)
            assertOk(selector.popup.visible, "camera dropdown opens")
            // Select the first actual dropdown entry with a mouse click.
            var entry = find(selector.popup.contentItem, function(i) { return i.text === "Front door" && i.clicked !== undefined })
            assertOk(entry !== null, "named camera appears in dropdown")
            mouseClick(entry)
            eventually(function() { return panel.selectedCameraId === firstId }, 4000)
            assertOk(!panel.configuring, "main selector switches feed without opening settings")
            equal(selector.displayText, "Front door", "selector updates after switch")
            panel.editSettings()
            assertOk(field("addCameraButton").visible, "add button is in Config")
            panel.selectCamera(1)
            eventually(function() { return panel.selectedCameraId === secondId }, 4000)
            assertOk(panel.configuring, "config selection stays in settings")
            panel.selectCamera(0)
            eventually(function() { return panel.selectedCameraId === firstId }, 4000)
            equal(field("cameraName").text, "Front door", "config selection populates camera form")
            equal(panel.config.username, "test-user", "switch restores per-camera credentials")
            equal(panel.config.url, "rtsp://127.0.0.1:1/front", "switch uses selected stream")
            panel.editSettings()
            field("cameraName").text = "Entrance"
            panel.submitProfile()
            eventually(function() { return panel.cameras[0].name === "Entrance" && !panel.configuring }, 4000)
            panel.editSettings(true)
            field("cameraName").text = "Entrance"
            field("cameraAddress").text = "rtsp://127.0.0.1:1/duplicate"
            panel.submitProfile()
            eventually(function() { return panel.message !== "" }, 4000)
            equal(panel.cameras.length, 2, "duplicate name leaves profiles intact")
            assertOk(panel.configuring, "failed save keeps form open")
            panel.configuring = false
            panel.selectCamera(1)
            eventually(function() { return panel.selectedCameraId === secondId }, 4000)
            for (var newCamera of [false, true]) {
                panel.editSettings(newCamera)
                field("cameraAddress").text = "rtsp://127.0.0.1:1/unsaved"
                panel.close()
                panel.open()
                assertOk(!panel.configuring && panel.streaming, "reopening from Config returns to main camera screen")
                equal(panel.selectedCameraId, secondId, "reopening keeps the selected camera")
                equal(panel.config.url, "rtsp://127.0.0.1:1/garage", "closing Config does not save its draft")
            }
            panel.close()
            var restored = newPanel.createObject(barWindow.contentItem)
            eventually(function() { return restored.cameras.length === 2 }, 4000)
            equal(restored.selectedCameraId, secondId, "last selected camera restored")
            restored.destroy()
            panel.runProfileOperation({action: "delete", id: secondId})
            eventually(function() { return panel.cameras.length === 1 }, 4000)
            equal(panel.selectedCameraId, firstId, "deleting selected camera selects remaining one")
            panel.runProfileOperation({action: "delete", id: firstId})
            eventually(function() { return panel.cameras.length === 0 }, 4000)
            assertOk(!panel.configured && panel.configuring, "last deletion returns to setup")
            panel.open(); panel.close(); panel.open()
            assertOk(panel.configuring, "camera setup remains available when no cameras exist")
            console.log("PASS: profile form, dropdown switching, rename, duplicate handling, persistence, deletion")
        }
        function runAppearance() {
            panel.config = {url: Qt.resolvedUrl("sample.mp4").toString(), username: "", password: ""}
            panel.configured = true; panel.configuring = false; panel.open()
            eventually(function() { return state().live }, 5000)
            var popup = find(panel, function(i) { return i.cardOrigin !== undefined })
            var content = popup.contentItem[0]
            // Give QtTest a window for key events even when the compositor has
            // not focused this pinned viewer after a synthetic mouse click.
            parent = content
            // Keep the synthetic interaction sequence safe from outside-click dismissal.
            // Explicit close/reopen and pin behavior are checked separately below.
            function click(item) { panel.pinned = true; wait(80); mouseClick(item); wait(80) }
            function field(name) { return find(content, function(i) { return i.objectName === name }) }
            var themeButton = field("themeButton")
            assertOk(themeButton !== null, "header offers a themes button")
            var feedFs = field("fullscreenButton")
            assertOk(feedFs !== null, "feed offers a fullscreen button")
            var editor = field("themeEditor")
            var chooser = field("videoStyle"), strength = field("tintStrength"), pixelSize = field("pixelSize")
            var apply = field("applyStyle"), effect = field("videoEffect")
            var overlayChooser = field("overlayStyle"), overlay = field("videoOverlay")
            assertOk(overlayChooser !== null && overlay !== null, "theme editor offers overlays")
            equal(overlayChooser.model[2], "Hackerman", "overlay chooser uses the Hackerman name")
            equal(overlay.mode, "default", "first run uses Default overlay")
            assertOk(overlay.item !== null, "Default draws corner borders")
            assertOk(!editor.visible, "theme editor starts hidden")
            var fullHeight = effect.height, beforeFrames = panel.framesReceived
            click(themeButton)
            wait(150)
            assertOk(editor.visible && !panel.configuring && state().live, "theme button opens editor while video plays")
            assertOk(effect.height >= 120 && effect.height < fullHeight, "editor leaves space for live feed")
            assertOk(editor.y >= effect.parent.y + effect.parent.height, "theme section sits below video")
            equal(panel.videoStyle, "theme", "first run uses theme tint")
            assertOk(!pixelSize.visible && strength.visible, "default theme tint shows strength slider")
            click(chooser)
            wait(100)
            assertOk(chooser.popup.visible, "video style dropdown opens")
            var choice = find(chooser.popup.contentItem, function(i) { return i.text === "Omarchy Pixel" && i.clicked !== undefined })
            assertOk(choice !== null, "Omarchy Pixel is available in dropdown")
            click(choice)
            assertOk(strength.visible && pixelSize.visible, "Omarchy Pixel shows both sliders")
            equal(pixelSize.value, 3, "default preserves previous pixel look")
            pixelSize.value = 8; strength.value = 60
            overlayChooser.currentIndex = 2
            wait(200)
            equal(effect.style, "theme-pixel", "style previews before saving; opened=" + panel.opened
                + ", editing=" + panel.editingAppearance + ", selected=" + chooser.currentIndex)
            equal(effect.pixelSize, 8, "pixel size previews before saving")
            equal(effect.strength, 0.6, "tint previews before saving")
            equal(overlay.mode, "hacker", "overlay previews before saving")
            assertOk(overlay.item !== null, "selected overlay is rendered")
            equal(panel.overlayStyle, "default", "overlay preview does not change saved setting")
            equal(panel.videoStyle, "theme", "preview does not change saved style")
            assertOk(panel.framesReceived > beforeFrames, "preview keeps receiving video")
            var universalAudio = field("audioButton")
            for (var styleIndex = 0; styleIndex < 4; styleIndex++) {
                chooser.currentIndex = styleIndex
                for (var overlayIndex = 0; overlayIndex < 3; overlayIndex++) {
                    overlayChooser.currentIndex = overlayIndex
                    wait(30)
                    assertOk(universalAudio.visible && universalAudio.enabled, "waveform available with every style and overlay")
                    click(universalAudio)
                    assertOk(!state().muted, "waveform unmutes with style " + styleIndex + " overlay " + overlayIndex)
                    click(universalAudio)
                    assertOk(state().muted, "waveform mutes with every style and overlay")
                }
            }
            chooser.currentIndex = 3; overlayChooser.currentIndex = 2
            wait(100)
            var restored = newPanel.createObject(barWindow.contentItem)
            wait(200)
            equal(restored.videoStyle, "theme", "draft stays local to current viewer")
            capture(content, "theme-preview")
            click(apply)
            eventually(function() { return !editor.visible && restored.videoStyle === "theme-pixel" }, 3000)
            equal(panel.tintStrength, 60, "tint strength saved")
            equal(panel.pixelSize, 8, "pixel size saved")
            equal(panel.overlayStyle, "hacker", "overlay saved")
            equal(restored.overlayStyle, "hacker", "other viewer receives saved overlay")
            equal(restored.tintStrength, 60, "other viewer receives saved tint")
            equal(restored.pixelSize, 8, "other viewer receives saved pixel size")
            eventually(function() { return effect.height === fullHeight }, 1000)
            var overlayTick = overlay.item.tick
            wait(600)
            assertOk(overlay.item.tick !== overlayTick, "terminal clock advances while real video frames arrive")
            var waveButton = field("audioButton")
            assertOk(waveButton.enabled && state().muted, "waveform starts ready to unmute the camera")
            click(waveButton)
            assertOk(!state().muted, "clicking waveform unmutes real audio output")
            waveButton.forceActiveFocus()
            keyClick(Qt.Key_Space)
            assertOk(state().muted, "keyboard activates waveform mute button")
            assertOk(waveButton.parent === overlay.parent, "waveform is independent of overlay selection")
            assertOk(find(content, function(i) { return i.text === "LIVE" || i.text === "OFFLINE" }) === null, "LIVE/OFFLINE chip is removed")
            var consoleLine = find(overlay.item, function(i) { return i.text === "$ monitor --stream" })
            assertOk(consoleLine !== null, "terminal readout is available")
            var headerLine = find(overlay.item, function(i) { return typeof i.text === "string" && i.text.indexOf(">_ ") === 0 })
            equal(headerLine.parent.color.a, 0, "terminal header background is transparent")
            assertOk(Math.abs(consoleLine.parent.parent.color.a - 0.39) < 0.01, "lower console background has half its previous opacity")
            var consoleBox = consoleLine.parent.parent
            assertOk(Math.abs(consoleBox.mapToItem(content, 0, consoleBox.height).y
                - feedFs.mapToItem(content, 0, feedFs.height).y) < 1,
                "console and fullscreen button align at the bottom")
            capture(content, "theme-applied")
            var savedWidth = panel.viewerWidth, savedHeight = panel.viewerHeight
            for (var size of [[860, 440], [420, 650], [420, 440]]) {
                panel.viewerWidth = size[0]; panel.viewerHeight = size[1]
                wait(150)
                var audioPosition = waveButton.mapToItem(overlay, 0, 0)
                assertOk(audioPosition.x >= overlay.width / 2
                    && audioPosition.x + waveButton.width <= overlay.width - overlay.item.inset - 4
                    && audioPosition.y >= overlay.item.inset + 4
                    && audioPosition.y + waveButton.height <= overlay.height,
                    "waveform stays inside video clear of top-right corner after resize")
                for (var control of feedFs.parent.children) {
                    if (control.text === undefined || !control.visible) continue
                    var position = control.mapToItem(overlay, 0, 0)
                    assertOk(position.x >= overlay.item.inset + 4
                        && position.x + control.width <= overlay.width - overlay.item.inset - 4,
                        "feed controls stay within video sides after resize")
                    assertOk(position.y >= 0
                        && position.y + control.height <= overlay.height - overlay.item.inset - 8,
                        "feed controls clear bottom overlay corners after resize")
                }
            }
            panel.viewerWidth = savedWidth; panel.viewerHeight = savedHeight
            wait(150)
            for (var profile of ["default", "coder", "hacker"]) {
                panel.overlayStyle = profile
                wait(100)
                var lowerConsole = field("terminalConsole")
                var topLine = find(overlay.item, function(i) { return typeof i.text === "string" && i.text.indexOf(">_ ") === 0 })
                equal(lowerConsole.visible, profile !== "default", "Coder and Hacker show the lower terminal")
                equal(topLine.visible, profile === "hacker", "only Hacker shows the top terminal")
                equal(field("terminalScanBand").visible, profile === "hacker", "only Hacker shows the sweep")
                if (lowerConsole.visible) {
                    assertOk(lowerConsole.mapToItem(content, lowerConsole.width, 0).x + 8
                        <= feedFs.mapToItem(content, 0, 0).x, "terminal clears the fullscreen button")
                }
                capture(content, "profile-" + profile)
            }
            equal(effect.parent.border.color.toString(), Color.accent.toString(), "video frame follows theme accent")
            equal(effect.style, "theme-pixel", "applied effect remains after editor hides")
            click(themeButton)
            equal(chooser.currentIndex, 3, "reopening loads saved style")
            equal(overlayChooser.currentIndex, 2, "reopening loads saved overlay")
            overlayChooser.currentIndex = 1
            wait(100)
            assertOk(waveButton.visible, "waveform remains available with HUD")
            chooser.currentIndex = 2
            assertOk(pixelSize.visible && !strength.visible, "Pixel shows only pixel size")
            chooser.currentIndex = 1
            assertOk(!pixelSize.visible && strength.visible, "Omarchy shows only tint strength")
            click(themeButton)
            assertOk(!editor.visible, "theme button can dismiss editor")
            equal(effect.style, "theme-pixel", "dismissal restores applied appearance")
            equal(overlay.mode, "hacker", "dismissal restores applied overlay")
            click(themeButton)
            chooser.currentIndex = 0
            panel.editSettings()
            assertOk(!editor.visible && !chooser.visible, "connection Config contains no theme controls")
            panel.configuring = false
            equal(effect.style, "theme-pixel", "opening connection Config discards preview")
            click(themeButton)
            chooser.currentIndex = 0
            panel.close()
            panel.open()
            assertOk(!editor.visible, "closing viewer hides theme section")
            equal(effect.style, "theme-pixel", "closing viewer discards preview")
            click(themeButton)
            chooser.currentIndex = 0
            click(apply)
            eventually(function() { return !editor.visible && restored.videoStyle === "original" }, 3000)
            restored.destroy()
            panel.close(); panel.configured = false
            console.log("PASS: live theme preview, apply/collapse, persistence, shared settings, draft cancellation")
        }
        function runEffectPixels() {
            effectWindow.visible = true
            wait(200)
            var original = grabImage(fixture)
            fixtureEffect.style = "pixel"
            wait(200)
            assertOk(!fixtureEffect.failed, "pixel shader compiles")
            var pixel = grabImage(fixture)
            assertOk(!original.equals(pixel), "pixel style changes the rendered image")
            var scale = pixel.width / fixture.width
            // Sample block interiors; exact boundaries can round to either texel on the GPU.
            equal(pixel.red(31 * scale, 80 * scale), pixel.red(32 * scale, 80 * scale), "adjacent pixels form crisp blocks")
            assertOk(pixel.red(34 * scale, 80 * scale) !== pixel.red(31 * scale, 80 * scale), "neighboring blocks retain detail")
            fixtureEffect.pixelSize = 12
            wait(200)
            var coarse = grabImage(fixture)
            equal(coarse.red(25 * scale, 80 * scale), coarse.red(33 * scale, 80 * scale), "larger size creates larger blocks")
            assertOk(!pixel.equals(coarse), "changing pixel size updates rendered output")
            fixtureEffect.pixelSize = 1
            wait(200)
            assertOk(sameResampledImage(original, grabImage(fixture)), "one pixel size preserves detail on scaled monitors")
            fixtureEffect.pixelSize = 3
            var oldBackground = Color.background, oldForeground = Color.foreground, oldAccent = Color.accent
            try {
                Color.background = "black"; Color.foreground = "red"; Color.accent = "red"
                fixtureEffect.style = "theme"; fixtureEffect.strength = 1
                wait(200)
                var tinted = grabImage(fixture)
                assertOk(tinted.red(180 * scale, 80 * scale) > 100 && tinted.green(180 * scale, 80 * scale) < 5,
                    "theme maps feed to the active palette")
                equal(tinted.red(20 * scale, 25 * scale), 255, "overlay remains sharp and unfiltered")
                fixtureEffect.strength = 0
                wait(200)
                assertOk(sameResampledImage(original, grabImage(fixture)), "zero tint preserves original colors on scaled monitors")
                fixtureEffect.strength = 1
                Color.foreground = "lime"; Color.accent = "lime"
                wait(200)
                var changed = grabImage(fixture)
                assertOk(changed.green(180 * scale, 80 * scale) > 100 && changed.red(180 * scale, 80 * scale) < 5,
                    "theme switches update the existing effect")
                fixtureEffect.style = "theme-pixel"
                wait(200)
                var combined = grabImage(fixture)
                equal(combined.green(31 * scale, 80 * scale), combined.green(32 * scale, 80 * scale), "combined style retains crisp pixels")
                fixtureEffect.active = false
                wait(100)
                assertOk(original.equals(grabImage(fixture)) && fixtureEffect.item === null, "inactive effect releases capture and restores source")
            } finally {
                Color.background = oldBackground; Color.foreground = oldForeground; Color.accent = oldAccent
                fixtureEffect.style = "original"; fixtureEffect.active = true
                effectWindow.visible = false
            }
            console.log("PASS: rendered pixels, tint strength, live palette changes, sharp overlay, effect cleanup")
        }
        function cpuTicks() {
            processStats.reload()
            var fields = processStats.text().split(") ")[1].split(" ")
            return Number(fields[11]) + Number(fields[12])
        }
        function runOverlayPixels() {
            effectWindow.visible = true
            wait(150)
            var original = grabImage(fixture)
            fixtureOverlay.mode = "default"; fixtureOverlay.active = true
            wait(100)
            var corner = find(fixtureOverlay.item, function(i) { return i.objectName === "overlayCorner" })
            equal(corner.color.toString(), "#ff4545", "offline corners are red")
            assertOk(find(fixtureOverlay.item, function(i) { return i.objectName === "overlayActivityDot" }) === null,
                "Default has no activity dots")
            assertOk(!find(fixtureOverlay.item, function(i) { return i.objectName === "terminalScanBand" }).visible,
                "Default has no scanning band")
            var defaultTick = fixtureOverlay.item.tick
            wait(200)
            equal(fixtureOverlay.item.tick, defaultTick, "Default needs no terminal animation clock")
            fixtureOverlay.live = true
            equal(corner.color.toString(), Color.accent.toString(), "connected corners use theme accent")
            var defaultImage = grabImage(fixture)
            capture(fixture, "overlay-default")
            fixtureOverlay.mode = "coder"
            wait(150)
            var hudImage = grabImage(fixture)
            assertOk(!defaultImage.equals(hudImage), "Coder adds right-side activity dots")
            assertOk(find(fixtureOverlay.item, function(i) { return i.objectName === "overlayActivityDot" }) !== null,
                "Coder includes activity dots")
            assertOk(!find(fixtureOverlay.item, function(i) { return i.objectName === "terminalScanBand" }).visible,
                "Coder has no scanning band")
            capture(fixture, "overlay-coder")
            fixtureOverlay.mode = "hacker"; fixtureOverlay.live = false
            wait(150)
            var terminalImage = grabImage(fixture)
            assertOk(!hudImage.equals(terminalImage), "terminal overlay has its own visible design")
            capture(fixture, "overlay-terminal")
            fixtureOverlay.live = true
            fixtureOverlay.framesReceived = 42
            wait(100)
            var liveImage = grabImage(fixture)
            assertOk(!terminalImage.equals(liveImage), "overlay reflects actual live status")
            wait(350)
            assertOk(!liveImage.equals(grabImage(fixture)), "live terminal overlay animates")
            eventually(function() {
                return find(fixtureOverlay.item, function(i) { return typeof i.text === "string" && i.text.indexOf("0000002A") >= 0 }) !== null
            }, 1500)
            var terminal = fixtureOverlay.item
            var band = find(terminal, function(i) { return i.objectName === "terminalScanBand" })
            assertOk(band !== null, "scanner exists")
            var wave = fixtureWave
            wave.visible = true
            assertOk(!wave.enabled, "waveform button is disabled without an audio track")
            var audioRequests = 0
            var onAudioRequest = function() { audioRequests++ }
            wave.clicked.connect(onAudioRequest)
            mouseClick(wave)
            equal(audioRequests, 0, "disabled waveform cannot request audio playback")
            wave.clicked.disconnect(onAudioRequest)
            var waveImage = grabImage(wave)
            wait(250)
            assertOk(!waveImage.equals(grabImage(wave)), "decorative waveform animates")
            wave.visible = false
            var waveTick = wave.tick
            wait(200)
            equal(wave.tick, waveTick, "hidden waveform stops its timer")
            var previous = band.y
            var minY = previous, maxY = previous, stationary = 0, down = 0, up = 0
            // Exercise more than the reported 30-second freeze, including status churn.
            for (var sample = 0; sample < 400; sample++) {
                fixtureOverlay.live = false
                fixtureOverlay.live = true
                wait(80)
                var current = band.y
                if (Math.abs(current - previous) < 0.1) stationary++
                else stationary = 0
                assertOk(stationary < 3, "scan keeps moving despite frame-status changes")
                if (current > previous) down++
                if (current < previous) up++
                minY = Math.min(minY, current); maxY = Math.max(maxY, current)
                assertOk(current >= terminal.inset - 1 && current + band.height <= terminal.height - terminal.inset + 1,
                    "scanner stays inside the video")
                previous = current
            }
            assertOk(down > 100 && up > 100, "scanner continuously travels in both directions")
            assertOk(maxY - minY > (terminal.height - terminal.inset * 2 - band.height) * 0.9,
                "scanner sweeps the full video height")
            fixtureOverlay.live = false
            previous = band.y
            wait(400)
            equal(band.y, previous, "Hackerman sweep freezes in place while offline")
            fixtureOverlay.live = true
            assertOk(Math.abs(band.y - previous) < 1, "reconnection preserves the sweep position")
            wait(240)
            assertOk(Math.abs(band.y - previous) > 1, "Hackerman sweep resumes when connected")
            terminal.visible = false
            wait(100)
            var hiddenTick = terminal.tick, hiddenProgress = terminal.scanProgress
            wait(250)
            equal(terminal.tick, hiddenTick, "hidden overlay stops its decoration clock")
            equal(terminal.scanProgress, hiddenProgress, "hidden overlay stops its sweep")
            terminal.visible = true
            wait(100)
            liveImage = grabImage(fixture)
            var oldAccent = Color.accent
            try {
                Color.accent = Color.accent.toString() === "#ff0000" ? "lime" : "red"
                wait(100)
                assertOk(!liveImage.equals(grabImage(fixture)), "overlay follows palette changes")
            } finally { Color.accent = oldAccent }
            fixtureOverlay.active = false
            wait(100)
            assertOk(fixtureOverlay.item === null && original.equals(grabImage(fixture)), "inactive overlay releases geometry")
            fixtureOverlay.mode = "default"; fixtureOverlay.active = true
            wait(100)
            assertOk(fixtureOverlay.item !== null && !original.equals(grabImage(fixture)), "Default restores corner borders")
            fixtureOverlay.active = false
            effectWindow.visible = false
            console.log("PASS: Default/Coder/Hacker pixels, continuous sweep, decorative waveform, frame counter, hidden pause, palette binding, overlay cleanup")
        }
        function runVideoStyles(benchmark) {
            panel.config = {url: Qt.resolvedUrl("sample.mp4").toString(), username: "", password: ""}
            panel.configured = true; panel.configuring = false; panel.open(); panel.pinned = true
            eventually(function() { return state().live }, 5000)
            var popup = find(panel, function(i) { return i.cardOrigin !== undefined })
            var effect = find(popup.contentItem[0], function(i) { return i.objectName === "videoEffect" })
            var baseline
            for (var style of ["original", "theme", "pixel", "theme-pixel"]) {
                panel.videoStyle = style
                wait(300)
                assertOk(!effect.failed, style + " shader loads")
                var beforeFrames = panel.framesReceived, beforeTime = Date.now(), beforeCpu = cpuTicks()
                wait(benchmark ? 4000 : 400)
                assertOk(panel.framesReceived > beforeFrames && state().live, style + " receives live video")
                var elapsed = Date.now() - beforeTime
                if (benchmark) console.log("BENCHMARK", style,
                    "CPU % of one core:", ((cpuTicks() - beforeCpu) / Number(Quickshell.env("CAMERA_CLOCK_TICKS")) / (elapsed / 1000) * 100).toFixed(1),
                    "frames/s:", ((panel.framesReceived - beforeFrames) / (elapsed / 1000)).toFixed(1))
                var frame = grabImage(effect.parent)
                capture(effect.parent, style)
                if (style === "original") { baseline = frame; assertOk(effect.item === null, "Original bypasses effect") }
                if (style === "theme" || style === "theme-pixel") assertOk(!baseline.equals(frame), style + " filters actual video frames")
            }
            panel.editSettings()
            assertOk(effect.item === null, "settings unload video effect")
            panel.close()
            panel.videoStyle = "original"
            console.log("PASS: playback in all four styles and resource cleanup")
        }
        function state() { return JSON.parse(panel.playbackStatus()) }
        function runReconnect() {
            panel.config = {url: "rtsp://127.0.0.1:1/live", username: "", password: ""}
            panel.configured = true
            panel.configuring = false
            panel.open()
            eventually(function() { return state().reconnectPending }, 4000)
            equal(state().retryDelay, 2000, "first retry delay")
            eventually(function() { return state().retryAttempt >= 2 }, 5000)
            equal(state().retryDelay, 4000, "second retry delay")
            eventually(function() { return state().retryAttempt >= 3 }, 6000)
            equal(state().retryDelay, 8000, "third retry delay")
            panel.scheduleReconnect("Duplicate failure")
            equal(state().retryAttempt, 3, "duplicate failure does not enqueue another retry")
            panel.retryAttempt = 5
            panel.play(false)
            eventually(function() { return state().reconnectPending }, 4000)
            equal(state().retryDelay, 30000, "retry delay capped")
            panel.play()
            eventually(function() { return state().reconnectPending }, 4000)
            equal(state().retryDelay, 2000, "manual retry resets delay")
            panel.editSettings()
            assertOk(!state().reconnectPending, "settings cancel reconnect")
            wait(2200)
            assertOk(!state().playing && !state().timeoutRunning, "settings remain stopped")
            panel.configuring = false
            eventually(function() { return state().reconnectPending }, 4000)
            panel.close()
            assertOk(!state().reconnectPending, "close cancels reconnect")
            wait(2200)
            assertOk(!state().playing && !state().timeoutRunning, "closed viewer remains stopped")
            panel.open()
            eventually(function() { return state().reconnectPending }, 4000)
            panel.config = {url: Qt.resolvedUrl("sample.mp4").toString(), username: "", password: ""}
            panel.play(false)
            eventually(function() { return state().live }, 5000)
            equal(state().retryAttempt, 0, "healthy frames reset retry delay")
            assertOk(!state().reconnectPending, "healthy stream cancels retries")
            var player = find(panel, function(i) { return i.playbackState !== undefined && i.source !== undefined })
            player.stop()
            eventually(function() { return state().reconnectPending }, 2000)
            equal(state().retryDelay, 2000, "interrupted live stream retries")
            panel.config = {url: Qt.resolvedUrl("stall.mp4").toString(), username: "", password: ""}
            panel.play()
            eventually(function() { return state().live }, 5000)
            eventually(function() { return state().reconnectPending }, 7000)
            assertOk(state().message.indexOf("Video stalled.") === 0, "stalled frames trigger recovery")
            panel.close()
            console.log("PASS: automatic reconnect, backoff, recovery, stall detection, and cancellation")
        }
        function runDrag() {
            panel.open()
            panel.pinned = true
            wait(500)
            var popup = find(panel, function(i) { return i.cardOrigin !== undefined })
            console.log("POPUP", popup)
            var title = find(popup.contentItem[0], function(i) { return i.objectName === "headerDragSpace" })
            console.log("TITLE", title)
            console.log("GEOMETRY", title.width, title.height, popup.cardOrigin)
            var pin = find(popup.contentItem[0], function(i) { return i.objectName === "pinSwitch" || i.checkable === true })
            assertOk(pin !== null && pin.checked, "pin toggle reflects pinned mode")
            mouseClick(pin)
            assertOk(!panel.pinned && !pin.checked, "pin toggle unpins")
            mouseClick(pin)
            assertOk(panel.pinned && pin.checked, "pin toggle pins")
            console.log("PASS: pin toggle switches both ways")
            var origin = Qt.point(popup.cardOrigin.x, popup.cardOrigin.y)
            mousePress(title, 20, title.height / 2, Qt.LeftButton)
            mouseMove(title, -80, title.height / 2 + 100, 100)
            mouseRelease(title, 20, title.height / 2, Qt.LeftButton)
            wait(100)
            console.log("AFTER", popup.cardOrigin)
            assertOk(popup.cardOrigin.x < origin.x, "moves left")
            assertOk(popup.cardOrigin.y > origin.y, "moves down")
            console.log("PASS: pinned mouse drag moved left and down")
            var header = title.parent
            var gapX = title.x + title.width / 2
            var beforeGap = Qt.point(popup.cardOrigin.x, popup.cardOrigin.y)
            mousePress(header, gapX, header.height / 2, Qt.LeftButton)
            mouseMove(header, gapX - 60, header.height / 2 + 60, 100)
            mouseRelease(header, gapX, header.height / 2, Qt.LeftButton)
            wait(100)
            assertOk(popup.cardOrigin.x < beforeGap.x && popup.cardOrigin.y > beforeGap.y,
                "empty header space drags pinned camera")
            console.log("PASS: empty header drag area")
            panel.configuring = false
            wait(250)
            var status = find(popup.contentItem[0], function(i) { return i.text === "OFFLINE" || i.text === "LIVE" })
            var theme = find(popup.contentItem[0], function(i) { return i.objectName === "themeButton" })
            var feedFs = find(popup.contentItem[0], function(i) { return i.objectName === "fullscreenButton" })
            assertOk(status === null, "no status chip while offline")
            assertOk(theme !== null && theme.visible, "themes button visible")
            console.log("PASS: theme control visible without status chip")
            mouseMove(feedFs, 10, 10)
            wait(250)
            equal(popup.chromeOpacity, 1, "hover restores surrounding UI")
            mouseMove(popup.contentItem[0], -80, -80)
            wait(250)
            equal(popup.chromeOpacity, 0, "leaving pinned viewer hides surrounding UI")
            equal(title.parent.parent.opacity, 0, "header fades out")
            equal(feedFs.parent.opacity, 1, "feed controls remain opaque")
            equal(feedFs.parent.parent.opacity, 1, "feed remains opaque")
            panel.pinned = false
            wait(250)
            equal(popup.chromeOpacity, 1, "unpinned UI stays visible without hover")
            panel.pinned = true
            wait(250)
            console.log("PASS: pinned hover fade preserves feed and overlay controls")
            var saved = Qt.point(popup.cardOrigin.x, popup.cardOrigin.y)
            eventually(function() { return !JSON.parse(panel.playbackStatus()).positionPending }, 3000)
            equal(panel.positionSaveError, "", "position saved")
            panel.close()
            var restoredPanel = newPanel.createObject(barWindow.contentItem)
            wait(500)
            restoredPanel.open()
            restoredPanel.pinned = true
            var restored = find(restoredPanel, function(i) { return i.cardOrigin !== undefined })
            eventually(function() { return restored.savedPosition !== null }, 3000)
            equal(restored.cardOrigin.x, saved.x, "new viewer restores saved x")
            equal(restored.cardOrigin.y, saved.y, "new viewer restores saved y")
            restored.savedPosition = Qt.point(32768, 32768)
            restoredPanel.pinned = false
            restoredPanel.pinned = true
            assertOk(restored.cardOrigin.x + restored.contentWidth <= restored.screenW, "position clamped horizontally")
            assertOk(restored.cardOrigin.y + restored.contentHeight <= restored.screenH, "position clamped vertically")
            restoredPanel.close()
            restoredPanel.destroy()
            console.log("PASS: saved position survives new viewer and clamps to screen")

        }
    }
}
