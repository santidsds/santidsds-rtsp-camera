"""Run isolated Qt mouse/playback checks in an active Omarchy Wayland session."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="camera-checks-") as temporary:
    work = Path(temporary)
    # A configured camera already has this directory before opening its live feed.
    (work / "config" / "rtsp-camera").mkdir(parents=True)
    for name in ("Commons", "Ui"):
        (work / name).symlink_to(Path("/usr/share/omarchy/shell") / name)
    (work / "Camera").symlink_to(repo)
    shutil.copy2(repo / "tests/CameraChecks.qml", work / "shell.qml")
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
        "color=c=blue:s=320x240:r=10", "-f", "lavfi", "-i",
        "anullsrc=channel_layout=mono:sample_rate=44100", "-t", "60",
        "-c:v", "mpeg4", "-c:a", "aac",
        str(work / "sample.mp4")
    ], check=True)
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
        "color=c=blue:s=320x240:r=1/10", "-t", "20", "-c:v", "mpeg4",
        str(work / "stall.mp4")
    ], check=True)
    # A real HEVC (hvc1) MP4 like sdclip.py makes, and a stand-in for sdclip.py.
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
        "testsrc=size=320x240:rate=12", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=8000",
        "-t", "4", "-c:v", "libx265", "-x265-params", "log-level=none", "-tag:v", "hvc1",
        "-c:a", "aac", "-shortest", str(work / "clip.mp4")
    ], check=True)
    (work / "fake_clip.py").write_text('''import json, os, signal, sys, time
work = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
camera = args[args.index("--camera") + 1]
def say(data):
    print(json.dumps(data), flush=True)
if "--save" in args:
    open(os.path.join(work, "clip-saved"), "w").write(args[args.index("--save") + 1])
    say({"ok": True, "path": os.path.join(work, "saved.mp4")})
elif camera == "front":
    say({"progress": 262144})
    say({"ok": True, "path": os.path.join(work, "clip.mp4"), "partial": True})
elif camera == "broken":
    say({"ok": False, "error": "no-recording"})
    sys.exit(1)
elif camera == "slow":
    def cancelled(*_):
        open(os.path.join(work, "clip-cancelled"), "w").write("cancelled")
        say({"ok": False, "error": "cancelled"})
        sys.exit(1)
    signal.signal(signal.SIGTERM, cancelled)
    say({"progress": 1048576})
    time.sleep(30)
''')
    environment = dict(os.environ, XDG_CONFIG_HOME=str(work / "config"),
                       QT_QUICK_CONTROLS_STYLE="Basic", CAMERA_CLOCK_TICKS=str(os.sysconf("SC_CLK_TCK")))
    environment["CAMERA_TEST_FAKE_CLIP"] = str(work / "fake_clip.py")
    environment["QML_XHR_ALLOW_FILE_READ"] = "1"
    screen = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--screen=")), "")
    if screen:
        environment["CAMERA_TEST_SCREEN"] = screen
    if "--reconnect-only" in sys.argv[1:]:
        environment["CAMERA_TEST_RECONNECT_ONLY"] = "1"
    if "--dual-only" in sys.argv[1:]:
        environment["CAMERA_TEST_DUAL_ONLY"] = "1"
    if "--ui-only" in sys.argv[1:]:
        environment["CAMERA_TEST_UI_ONLY"] = "1"
    if "--benchmark" in sys.argv[1:]:
        environment["CAMERA_TEST_BENCHMARK"] = "1"
    if "--capture" in sys.argv[1:]:
        captures = Path("/tmp/rtsp-camera-captures")
        captures.mkdir(exist_ok=True)
        environment["CAMERA_TEST_CAPTURE_DIR"] = str(captures)
    result = subprocess.run(["quickshell", "-p", str(work), "--no-color"],
                            env=environment, capture_output=True, text=True, timeout=150)
    output = result.stdout + result.stderr
    print(output)
    if result.returncode or "CAMERA_CHECKS_PASSED" not in output or "CAMERA_CHECKS_FAILED" in output:
        raise SystemExit(1)
