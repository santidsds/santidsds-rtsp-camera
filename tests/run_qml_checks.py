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
    environment = dict(os.environ, XDG_CONFIG_HOME=str(work / "config"),
                       QT_QUICK_CONTROLS_STYLE="Basic", CAMERA_CLOCK_TICKS=str(os.sysconf("SC_CLK_TCK")))
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
