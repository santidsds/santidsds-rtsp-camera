# RTSP Camera for Omarchy

Bar plugin for [Omarchy](https://omarchy.org) (Arch Linux + Quickshell) that
shows RTSP camera feeds in a themed, pinnable card on your desktop.

![RTSP Camera with the new header and Hackerman overlay](docs/assets/showcase.png)

---

## What it does

- **Bar widget** — camera icon on the right side of the Omarchy bar. Click to
  open the viewer; click again or click outside to close (unless pinned).
- **Profiles** — save up to 32 cameras (name + RTSP URL + credentials). Switch
  from the camera menu in the toolbar. The last camera is remembered across
  monitors.
- **Viewer** — resizable card (drag corners; double-click to reset). It fits
  the video like Picture in Picture. Size and per-monitor pinned position
  persist under `~/.config/rtsp-camera/`.
- **Dual view** — shows the selected camera and a second saved camera together.
  Wide cards place them side by side; narrow cards stack them. The split-view button toggles
  the individual view. Each tile reconnects independently; audio plays from
  one camera at a time. Use a tile's **⛶** to enlarge it, then Esc to return.
- **Pin** — the pin button keeps the card above other windows; drag the empty
  toolbar to move it.
  Chrome fades when the pointer leaves; hover brings it back. Pin resets on close.
- **Streaming** — audio starts muted (waveform toggle), auto-reconnect with
  backoff (2→30s), status dots turn orange while connecting and red while
  offline. The toolbar's full-screen button or a tile's **⛶** enters full
  screen (Esc exits).
- **Appearance** — live preview of video styles (Original / Omarchy / Pixel /
  Omarchy Pixel) and overlays (Default / Coder / Hackerman). **Apply** saves
  for every camera; dismissing the section discards unapplied changes.
- **Motion** — gallery of still frames from the last 24h (see below).

Settings live in `$XDG_CONFIG_HOME/rtsp-camera/` (typically
`~/.config/rtsp-camera/`). Camera passwords are mode-0600; credentials go to
the save helper over stdin, never on the command line. RTSP is not encrypted —
prefer RTSps if your camera supports it.

---

## Design

The viewer follows macOS conventions while keeping the Omarchy theme's
colors (on a grey theme the accent reads as macOS Graphite). Text uses SF Pro
when installed, otherwise Inter, otherwise the Omarchy font.

| Area | Design |
|------|--------|
| **Toolbar** | Camera menu with a status dot → **Live / Motion** segmented control → icon buttons for two-camera view, appearance, settings, keep-on-top and full screen. Narrow cards switch the segments to icons. Esc or clicking outside closes the viewer. |
| **Video** | Each tile hugs its stream's aspect ratio with rounded corners and a hairline edge — no letterboxing. Glass controls: speaker button (widens with level bars while audio plays) and full screen. Dual tiles show a name pill with a status dot. |
| **Status** | Green dot = live, pulsing orange = connecting, red = offline/retrying. Connection messages appear in a glass capsule with a spinner. |
| **Sizing** | Like Picture in Picture, the live card fits the video: the saved height is an upper bound, and corner drags scale proportionally. The appearance inspector grows the card while open. |
| **Appearance** | Inspector panel with segmented controls for video style and overlay, macOS sliders, and Cancel / Apply. The Default overlay no longer draws corner brackets (Coder and Hackerman keep them). |
| **Settings** | Grouped form (Connection, Authentication) with inline fields, a storage footnote, **Delete Camera** (asks to confirm), Cancel and Save. The camera menu also offers **Add Camera…**. |
| **Motion** | Photos-style grid with rounded thumbnails and time captions, a listener status chip, an empty state, and a full-size viewer with ← / → navigation and Esc. |
| **Tooltips / cursors** | `PanelToolTip` and `PointerArea`, as before. |

---

## Functionality changes

- **Motion still gallery** — **Live / Motion** in the toolbar. `motiond.py`
  captures via ONVIF PullPoint (HTTP snapshot fallback). Files in
  `~/.local/share/rtsp-camera/motion/` (0700), pruned at **24h** or **400
  files**. Retention/camera in `motion.json` (0600). Optional user unit:
  [`contrib/yani-camera-motion.service`](contrib/yani-camera-motion.service).

  ```sh
  cp contrib/yani-camera-motion.service ~/.config/systemd/user/
  systemctl --user daemon-reload
  systemctl --user enable --now yani-camera-motion.service
  ```

  Without the service you can still browse stills already on disk; opening
  **Motion** only lists files, it does not start the loop.

- **Stream pauses for the gallery** — player tears down while Motion is open;
  **Live** reconnects.

- **Auto-bind** — first run binds the gallery to the selected camera
  (`selectedId`), else the first profile.

- **Pinned input mask** — `CameraPopup.extraInput` is unioned into the
  layer-shell `Region`, so dropdown rows that hang past the card stay
  clickable while pinned. Mask clears when all popups close.

- **`chromeForce`** — driven by any combo popup `opened` (and card move).

- **`Controls.Button`** — pill buttons import `QtQuick.Controls as Controls`
  so they aren’t shadowed by Omarchy’s `qs.Ui.Button` (no `contentItem` /
  `hovered`).

- **Tests** — `test_motiond.py` (prune/list/creds, no network) + existing
  `test_config.py`. `.gitignore` also excludes `motion.json`,
  `appearance.json`, `position-*.json`, `.profiles.lock`, `.status.json`.

---

## Requirements

- Omarchy 4 (Quickshell plugin system)
- Qt 6 Multimedia + backend (e.g. `qt6-multimedia-ffmpeg`)
- Python 3 (stdlib only)
- RTSP/RTSps camera; for motion: ONVIF or HTTP snapshot + optional user service

Tested: Omarchy 4.0.3, Quickshell 0.3.1, Qt 6.11.2. Runs inside the shell
process; no root, no runtime downloads. Motion service is opt-in.

---

## Install

```sh
omarchy plugin add https://github.com/santidsds/santidsds-rtsp-camera.git --enable
```

Upstream original:

```sh
omarchy plugin add https://github.com/Yani3rt/rtsp-camera-plugin.git --enable
```

First open → **Config** → name + `rtsp://…` + user/password → **Save &
connect**. Example only: `rtsp://192.0.2.10:554/stream`. Put credentials in
the fields, not in the URL.

Update a git install: `omarchy plugin update yani.camera`

**Local dev:** copy this tree to `~/.config/omarchy/plugins/yani.camera/`
(including `shaders/` and license files), then
`omarchy-shell shell rescanPlugins` and
`omarchy plugin enable yani.camera --section right`.

---

## Themes (video style & overlay)

Open **Appearance** (palette icon) from the toolbar. Changes preview live; **Apply** saves for
all cameras/monitors (`appearance.json`). Closing the viewer or opening
Config discards unapplied edits.

| Video style | Look |
|-------------|------|
| **Original** | No filter / no effect texture. |
| **Omarchy** (default) | Soft blend into the current Omarchy palette. |
| **Pixel** | Crisp blocks, original colors (size 1–16 px, default 3). |
| **Omarchy Pixel** | Pixel blocks + theme tint. |

Themed styles add **Tint strength** (0–100%, default 35%). Pixel styles add
**Pixel size**.

| Overlay | Adds |
|---------|------|
| **Default** | Corner borders + waveform mute. |
| **Coder** | + activity dots + terminal status / frame counter. |
| **Hackerman** | + scanlines, sweep band, top header, block cursor. |

Coder/Hackerman corner brackets are red offline, accent when frames arrive. Overlays fit
the video (letterbox untouched), sit under playback controls, and use one GPU
texture + one shader — no per-frame Python. Needs a working Qt Quick GPU
backend for filtered styles.

---

## Verify

```sh
omarchy plugin validate .
python3 -m unittest discover -s . -p 'test_*.py'
python3 tests/run_qml_checks.py --ui-only   # layout; full run needs FFmpeg/QtTest
# Optional: --screen=<output> runs the test surfaces on another (e.g. headless) monitor
```

Rebuild the shader after editing `shaders/video.frag`:

```sh
/usr/lib/qt6/bin/qsb --glsl '100 es,120,150' --hlsl 50 --msl 12 \
  -o shaders/video.frag.qsb shaders/video.frag
```

---

## Disable / remove

```sh
omarchy plugin disable yani.camera    # keep settings
omarchy plugin remove yani.camera     # remove plugin; settings remain
```

To wipe data, delete `~/.config/rtsp-camera/` and
`~/.local/share/rtsp-camera/`. If you installed motion:
`systemctl --user disable --now yani-camera-motion.service` and remove the
unit from `~/.config/systemd/user/`.

---

## Credits / fork

**This repo:** [santidsds/santidsds-rtsp-camera](https://github.com/santidsds/santidsds-rtsp-camera)

Based on [`Yani3rt/rtsp-camera-plugin`](https://github.com/Yani3rt/rtsp-camera-plugin)
by **Yani (Yaniert Pascual)** — original RTSP bar widget, multi-camera
profiles, pinnable/resizable viewer, reconnect, themes, and overlays.

I (**Santiago Da Silva / santidsds**) interactively adapted that codebase:
header/control redesign, motion gallery + listener, Omarchy button-type
fixes, pinned input mask, and documentation. Design and functionality changes
in this fork are mine; the original work remains Yani’s. Published under the
same MIT license without claiming upstream authorship.

Upstream-only install is linked above under **Install**.

---

## License

[MIT](LICENSE).

- Original © **Yani (Yaniert Pascual)** — [`Yani3rt/rtsp-camera-plugin`](https://github.com/Yani3rt/rtsp-camera-plugin)
- This fork’s design & functionality changes © **Santiago Da Silva (santidsds)**
- Adapted Omarchy popup attribution: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

Showcase screenshot is from this fork. Marketplace notes: [PUBLISHING.md](PUBLISHING.md).
