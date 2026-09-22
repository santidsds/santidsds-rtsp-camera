# RTSP Camera for Omarchy

View your RTSP cameras from the Omarchy bar in Omarchy Style, with live theme
preview configurations, cool effects, overlays, a pinnable, resizable viewer
that you can move around your screen and pin to stay on top of your other apps,
and a motion-still gallery of the last 24 hours.

[![RTSP Camera with a pixelated video style and the Hackerman overlay](docs/assets/preview.gif)](docs/assets/preview.mp4)

Pixelated camera feed with the Hackerman overlay.
[Watch the MP4 recording](docs/assets/preview.mp4).

Surveillance-camera icon in the Omarchy bar. Click to view; **Config** opens the
camera name, RTSP address, username, and masked password form. Save & connect
persists that camera and opens its stream. Escape, the close button, clicking outside,
or clicking the bar icon closes the popup.

The top row has a camera dropdown alongside **Motion**, **Themes**, **Config**, the pin switch, and close.
Select a name to switch feeds. **Motion** opens stills captured in the last 24 hours (see below).
**Themes** opens the video style picker under the live view (Esc or **Themes** again closes it).
Open **Config** and use **+** beside the camera
name field to add another named camera. The fullscreen control sits at the bottom-right
of the video (Esc exits fullscreen first).
Selecting a camera in Config loads its settings without leaving the form.
Closing and reopening returns to the selected camera's main screen, discarding
unsaved Config edits.

The last selection is remembered and shared across monitor widgets. Names must be unique
(up to 64 characters), with up to 32 saved cameras. Switching cameras mutes audio and resets reconnect
attempts.

Drag either bottom corner to resize the viewer; double-click a corner to
reset its size. Dimensions are saved in `~/.config/rtsp-camera/view.json`
(or under `$XDG_CONFIG_HOME`) and shared across monitors. They survive closing
and shell restarts, and fit within the current monitor. Video retains its
aspect ratio while resizing.

Turn on the pin switch to keep the camera above other windows while using
your desktop. Turning it off restores outside-click dismissal. Close or Escape still closes
the pinned viewer. While pinned, drag the empty header space to move the viewer anywhere
within the current screen. Unpinning returns it to the bar icon. The dragged
position is saved separately for each monitor in `position-<monitor>.json` under
the camera config directory. Pinning again restores that position, including
after closing or restarting the shell, clamped to the current screen size.
The pin switch itself resets when the viewer is closed.
While pinned, the surrounding panel and header fade out when the pointer leaves
the viewer, and fade back in on hover. The camera feed and its overlay controls
remain visible, with no change to the feed's size or position. Open dropdowns
(camera selector, video style, overlay) stay visible and clickable while the card
is pinned; chrome stays visible while a dropdown is open, and the input mask
includes the popup so rows that hang past the card edge remain clickable.

Streaming stops while closed or editing settings. Audio starts muted. In every
video style and overlay, click the top-right waveform to mute or unmute; its slash
indicates muted audio. The waveform button also supports keyboard focus and Space.
Closing the popup or opening settings mutes audio again. Streams without an audio track disable the
audio control. The bottom-right **⛶** control toggles fullscreen. Failed connections, interrupted
streams, and five seconds without video frames trigger automatic reconnect.
Retries wait 2, 4, 8, 16, then at most 30 seconds between attempts; each connection
has a 20-second timeout. Receiving video resets the delay. Closing the viewer or
opening settings cancels retries.

Connection status is shown by the corner borders and terminal readouts. The audio
waveform and fullscreen control have transparent backgrounds and themed interaction
states. Controls overlay the feed.

## Motion captures

**Motion** in the header switches the viewer to a gallery of still frames saved by
the bundled listener (`motiond.py`). While the gallery is open the live stream is
paused; **Live** (or Escape) returns to the camera.

- Still frames are pulled via ONVIF PullPoint when the camera supports it, with an
  HTTP snapshot fallback.
- Files are stored under `~/.local/share/rtsp-camera/motion/` (mode 0700) and
  pruned after 24 hours or 400 files, whichever hits first.
- Retention and the target camera are read from `~/.config/rtsp-camera/motion.json`
  (mode 0600). The listener never logs credentials; it reads them from `config.json`
  the same way the UI does (over stdin / local file, never on the command line).
- A status line under the grid shows whether the listener is running and which
  camera it is bound to.

The listener is an optional user service (not started by the plugin itself).
A sample unit is in [`contrib/yani-camera-motion.service`](contrib/yani-camera-motion.service):

```sh
cp contrib/yani-camera-motion.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now yani-camera-motion.service
```

Without the service you can still browse stills already on disk; **Motion** only
lists files, it does not start the capture loop.

## Design changes (this fork)

These are UI/UX changes on top of the original plugin. They do not change the
streaming model or the settings format.

- **Header layout** — camera selector, **Motion**, **Themes**, **Config**, pill
  pin switch, and a round close (**×**) control, in that order.
- **Fullscreen** lives only at the bottom-right of the video (**⛶**); the header
  no longer carries a second fullscreen control.
- **Themes** is a first-class header button (the previous bottom-right palette
  icon is gone); it toggles the live video-style section under the feed.
- **Pill buttons** for Motion / Themes / Config / pin switch use Omarchy's
  `Controls.Button` with rounded hover fills instead of square chrome.
- **Dropdowns** (camera, video style, overlay) use rounded triggers and popups
  (radius 10/12) with themed row hover and `Style.font` captions.
- **Theme-editor labels** and status messages use Omarchy's font family and
  caption sizing so they match the rest of the shell.
- **Tooltips** use Omarchy's `PanelToolTip` (subtle caption style) on drag and
  resize grips instead of the default Qt tooltip.
- **Pointer cursors** — interactive overlays (`PointerArea`) set the correct
  cursor on buttons, dropdown triggers, sliders, and gallery tiles.
- **Pinned fade** — chrome opacity is forced on while any dropdown is open so
  the popup does not appear cut off against a faded card.
- **Gallery layout** — Motion opens as a third stack page beside live feed and
  Config, with the same header and card chrome.

## Functionality changes (this fork)

- **Motion still gallery** — new **Motion** control, `MotionGallery.qml`, and
  `motiond.py` (ONVIF / snapshot capture + 24h/400-file prune). Optional user
  service; unit under `contrib/`.
- **Live stream pauses while the gallery is open** — the player is torn down to
  save CPU/GPU; returning with **Live** reconnects automatically.
- **Camera auto-bind** — on first run with cameras already configured, the
  gallery targets the currently selected camera (`selectedId`), falling back to
  the first profile.
- **Pinned input mask** — `CameraPopup` accepts an `extraInput` rect that is
  unioned into the layer-shell `Region` mask, so open combo popups outside the
  card stay clickable while pinned.
- **Chrome force binding** — `chromeForce` is driven by any combo popup
  `opened` state (and refreshed when the card origin moves).
- **Explicit `Controls.Button`** — custom pill buttons import
  `QtQuick.Controls as Controls` so they are not shadowed by Omarchy's
  `qs.Ui.Button` (which has no `contentItem` / `hovered`).
- **Unit tests** — `test_motiond.py` covers prune, list, and credential
  helpers without touching the network; `test_config.py` remains the config
  helper suite.
- **`.gitignore`** now also excludes `motion.json`, `appearance.json`,
  `position-*.json`, `.profiles.lock`, and `.status.json` so local state can
  never be committed by mistake.

## Credits / based on

This repository is an interactive adaptation of
[`Yani3rt/rtsp-camera-plugin`](https://github.com/Yani3rt/rtsp-camera-plugin)
by **Yani (Yaniert Pascual)**.

The original project supplied the RTSP bar widget, multi-camera profiles,
pinnable/resizable viewer, reconnect logic, video themes, and overlays. I
interacted over that implementation — restyling the header and controls,
adding the motion-still gallery and listener, fixing Omarchy control-type
shadowing, and extending the pinned input mask — and am publishing the result
as a public fork under the same MIT license.

If you only need the original, install upstream:

```sh
omarchy plugin add https://github.com/Yani3rt/rtsp-camera-plugin.git --enable
```

## Requirements

- Omarchy 4 with its Quickshell plugin system and bundled shell components.
- Qt 6 Multimedia and a playback backend, such as `qt6-multimedia-ffmpeg`.
- Python 3; no pip packages are needed.
- An accessible RTSP/RTSPS camera and its stream path. Codec support depends on
  the installed [Qt Multimedia backend](https://doc.qt.io/qt-6/qtmultimedia-index.html).
- For motion capture: an ONVIF-capable camera (PullPoint) or an HTTP snapshot
  endpoint, plus the optional user service described above.

Tested on Omarchy 4.0.3, Quickshell 0.3.1, and Qt 6.11.2. Icons use Omarchy's
configured Nerd Font. The plugin runs in the existing shell process and invokes
its bundled Python helper for settings; the core widget installs no background
service, downloads no runtime code, and needs no root access. The motion
listener is opt-in. Dependencies must already
be installed. FFmpeg, QtTest, and Qt Shader Tools are development tools only
(the FFmpeg playback backend is still needed when chosen for playback).

## Video appearance

Click **Themes** in the top row to open the theme
section below the video. Choose **Video style** and adjust its sliders while the
feed keeps playing; changes preview immediately in this viewer:

- **Original**: unfiltered video, with no effect texture allocated.
- **Omarchy** (first-run default): gently blends the image into the current Omarchy palette.
- **Pixel**: crisp blocks with original colors.
- **Omarchy Pixel**: combines the pixel look with the theme tint.

The themed styles show a **Tint strength** slider (default 35%). Zero preserves
the original colors; 100% fully maps the image into the theme palette. Theme
changes update the filter automatically. Text and video controls remain sharp.

**Pixel** and **Omarchy Pixel** show a **Pixel size** slider from 1 to 16 px.
Higher values make larger blocks and a stronger pixelated look. The default is
3 px, including for settings saved before this slider was added. Click **Apply**
to save the size for every camera and monitor.

Use **Overlay** to add a theme-colored camera display to any video style:

- **Default**: corner borders and the waveform mute button.
- **Coder**: Default plus right-side activity dots pulsing up and down and a lower
  terminal readout with stream status and a received-frame counter.
- **Hackerman**: Coder plus scanlines, a smooth scanning band sweeping down and back up
  every six seconds, a top terminal header, and a blinking block cursor.
  The top header is transparent. Coder and Hackerman show their lower console in
  larger viewers, beside the theme button, with a background at 39% opacity.

Corner borders are red while offline or connecting and return to the theme accent
when video frames arrive. They remain visible even before the first frame.
Existing saved video styles are preserved. Older overlay choices migrate from
Off to Default, Sci-fi HUD to Coder, and Hacker terminal to Hackerman.

Overlays preview and save with the other appearance settings. They fit the video
image, leaving letterboxing alone, and sit behind playback controls. They use
bounded geometry with no extra video capture texture or per-frame Python work.
The video border follows the theme accent. Playback controls stay inside the video
when resizing, inset from overlay corners, with transparent backgrounds.
The scan band uses a native looping animation. Coder and Hackerman share
one 8 Hz decoration clock and sample the frame counter once per second. The universal
waveform button has its own 8 Hz clock; it is simulated and never analyzes audio.
The Hackerman sweep pauses in place while offline and resumes when video returns.
Other decorations continue while visible. Hiding the overlay stops its animations,
and closing the viewer releases it. Default's corner borders need no animation clock.

Appearance applies to every camera and monitor and is saved separately in
`~/.config/rtsp-camera/appearance.json` (or under `$XDG_CONFIG_HOME`). **Apply** saves
the preview and completely hides the theme section, returning the space to the
video. Click **Themes** again to dismiss the theme section. Dismissing
the section with that control, closing the viewer, or opening camera **Config** discards
unapplied changes. Other monitors see only the applied settings. Theme controls no
longer appear in Config. Closing the viewer or opening Config unloads the effect;
opening the theme section keeps playback and audio running.

Effects use one GPU capture texture and one shader, with no Python frame processing
or transcoding. They add rendering work and video memory, and do not reduce stream
decoding cost. A working Qt Quick GPU backend is required for filtered styles.

## Install

Install and enable from this repository (replace with your fork URL after push):

```sh
omarchy plugin add <this-repo-url>.git --enable
```

Upstream original:

```sh
omarchy plugin add https://github.com/Yani3rt/rtsp-camera-plugin.git --enable
```

The camera icon appears in the right bar section. Click it to open settings,
enter a camera name and its address, then choose **Save & connect**. For example,
`rtsp://192.0.2.10:554/stream` illustrates the format; replace the IP and path
with your camera's values. Enter credentials in the separate fields, not in
the URL. The first configured feed uses the Omarchy video style and Default overlay.

To update a git-managed installation:

```sh
omarchy plugin update yani.camera
```

For local development, copy the repository into
`~/.config/omarchy/plugins/yani.camera/`, including the compiled `shaders/`
assets and license notices, then run `omarchy-shell shell rescanPlugins` and
`omarchy plugin enable yani.camera --section right`. If an older manual copy
already occupies that directory, move it to a backup outside `plugins/`
before installing the git-managed version.

Settings live at `$XDG_CONFIG_HOME/rtsp-camera/config.json` (normally
`~/.config/rtsp-camera/config.json`). The password is stored as plaintext
in a mode-0600 file, inside a mode-0700 directory created on first save.
Credentials are passed to the save helper over stdin, not command arguments.
They are percent-encoded into the playback URL in memory. The plugin displays
generic playback errors; avoid enabling Qt/FFmpeg debug logging with real
credentials, since the backend may log stream URLs. RTSP itself is not
encrypted; use RTSPS if supported by the camera.

## Verify

```sh
omarchy plugin validate .
python3 -m unittest discover -s . -p 'test_*.py'
```

In an active Omarchy Wayland session, run the integration checks (requires
FFmpeg and QtTest). These use temporary settings, a refused localhost connection,
and generated video, without reading the saved camera credentials:

```sh
python3 tests/run_qml_checks.py
```

For layout-only changes, use `python3 tests/run_qml_checks.py --ui-only` to skip
the playback recovery checks. This still checks rendered effect pixels, live palette
updates, appearance persistence, and the settings controls.

`python3 tests/run_qml_checks.py --benchmark` compares process CPU usage and received
frame rate for all four styles using a generated 320×240, 10 fps clip. It is a small
local comparison, not a GPU benchmark or a guarantee for higher-resolution cameras.

The compiled Qt 6 shader is included, so installation needs no shader compiler.
After editing `shaders/video.frag`, rebuild it with Qt Shader Tools:

```sh
/usr/lib/qt6/bin/qsb --glsl '100 es,120,150' --hlsl 50 --msl 12 \
  -o shaders/video.frag.qsb shaders/video.frag
```

## Disable or remove

```sh
omarchy plugin disable yani.camera
```

To remove the plugin and its bar entry:

```sh
omarchy plugin remove yani.camera
```

Omarchy asks for confirmation. Disabling or removing the plugin retains your
camera profiles, credentials, appearance, motion stills, and window settings in
`${XDG_CONFIG_HOME:-$HOME/.config}/rtsp-camera/` and
`~/.local/share/rtsp-camera/`. To erase those as well, delete
those directories yourself after removal. If you installed the motion service,
also `systemctl --user disable --now yani-camera-motion.service` and remove
`~/.config/systemd/user/yani-camera-motion.service`. No other application
settings are stored there. Installing the plugin does not overwrite existing
camera settings.

## License

[MIT](LICENSE), copyright the original author (Yani) and contributors.
The adapted Omarchy popup retains its original attribution in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The preview recording and still
image show the original owner's pixelated camera feed, shared with permission.

Marketplace submission steps and a prepared listing are in [PUBLISHING.md](PUBLISHING.md).
