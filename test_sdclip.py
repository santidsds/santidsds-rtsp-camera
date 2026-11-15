"""Tests for sdclip.py: XM parsing, window choice, packet recovery, a fake camera end to end."""
import contextlib
import io
import json
import os
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest import mock

import motiond
import sdclip

AT = datetime(2026, 11, 15, 16, 43, 15)


def xm(marker, payload, kind=3, fps=12, stamp=0):
    if marker in (sdclip.VIDEO_I, sdclip.PICTURE):
        header = struct.pack("<BBBBII", kind, fps, 1920 // 8, 1080 // 8, stamp, len(payload))
    elif marker == sdclip.VIDEO_P:
        header = struct.pack("<I", len(payload))
    else:
        header = struct.pack("<BBH", kind, 2, len(payload))
    return b"\x00\x00\x01" + bytes([marker]) + header + payload


def entry(begin, end, kind="R"):
    return {"BeginTime": begin.strftime(sdclip.TIME_FORMAT), "EndTime": end.strftime(sdclip.TIME_FORMAT),
            "FileName": f"/idea0/{begin:%Y-%m-%d}/001/{begin:%H.%M.%S}-{end:%H.%M.%S}[{kind}][@1][0].h264"}


class ParseTests(unittest.TestCase):
    def test_drops_everything_before_the_first_key_frame(self):
        raw = (xm(sdclip.VIDEO_P, b"p0") + xm(sdclip.AUDIO, b"a0", kind=sdclip.G711A)
               + xm(sdclip.VIDEO_I, b"i1") + xm(sdclip.AUDIO, b"a1", kind=sdclip.G711A) + xm(sdclip.VIDEO_P, b"p1"))
        media = sdclip.parse_xm(raw)
        self.assertEqual((media.codec, media.fps, media.width, media.height), ("hevc", 12, 1920, 1080))
        self.assertEqual((bytes(media.video), bytes(media.audio), media.frames), (b"i1p1", b"a1", 2))

    def test_skips_garbage_false_markers_and_truncated_tail(self):
        false_marker = b"\x00\x00\x01\xfd" + struct.pack("<I", 0x7FFFFFFF)
        raw = (b"\x13\x37garbage" + false_marker + xm(sdclip.VIDEO_I, b"key", kind=2)
               + xm(sdclip.INFO, b"info", kind=1) + xm(sdclip.AUDIO, b"pcm", kind=0x0B)
               + xm(sdclip.VIDEO_P, b"next") + xm(sdclip.VIDEO_P, b"cut-short")[:-3])
        media = sdclip.parse_xm(raw)
        self.assertEqual(media.codec, "h264")
        self.assertEqual(bytes(media.video), b"keynext")
        self.assertEqual(bytes(media.audio), b"", "only G.711 A-law audio is kept")

    def test_key_frame_time_is_decoded(self):
        stamp = (26 << 26) | (11 << 22) | (15 << 17) | (16 << 12) | (43 << 6) | 11
        self.assertEqual(sdclip.xm_time(stamp), datetime(2026, 11, 15, 16, 43, 11))
        self.assertIsNone(sdclip.xm_time(0))

    def test_frame_rate_follows_the_audio_clock(self):
        media = sdclip.XmMedia(codec="hevc", fps=12, frames=120, audio=bytearray(80000))
        self.assertAlmostEqual(sdclip.effective_fps(media), 12.0)
        media.fps = 25  # header says 25, but 120 frames over 10 s of audio is 12 fps
        self.assertAlmostEqual(sdclip.effective_fps(media), 12.0)
        self.assertEqual(sdclip.effective_fps(sdclip.XmMedia(codec="hevc", fps=15, frames=30)), 15.0)


class WindowTests(unittest.TestCase):
    def test_continuous_recording(self):
        files = [entry(AT - timedelta(minutes=2), AT + timedelta(minutes=3))]
        self.assertEqual(sdclip.plan_window(files, AT),
                         (AT - timedelta(seconds=sdclip.BEFORE_SEC), AT + timedelta(seconds=sdclip.AFTER_SEC)))

    def test_motion_recording_extends_the_end(self):
        files = [entry(AT - timedelta(minutes=5), AT - timedelta(seconds=3)),
                 entry(AT - timedelta(seconds=3), AT + timedelta(seconds=40), "M")]
        start, end = sdclip.plan_window(files, AT)
        self.assertEqual(end, AT + timedelta(seconds=42))

    def test_still_just_before_the_motion_file_counts(self):
        files = [entry(AT + timedelta(seconds=2), AT + timedelta(seconds=10), "M")]
        self.assertIsNotNone(sdclip.plan_window(files, AT))

    def test_length_is_capped(self):
        files = [entry(AT, AT + timedelta(minutes=10), "M")]
        start, end = sdclip.plan_window(files, AT)
        self.assertEqual(end - start, timedelta(seconds=sdclip.MAX_SPAN_SEC))

    def test_gap_means_no_recording(self):
        files = [entry(AT - timedelta(minutes=10), AT - timedelta(minutes=5)), {"BeginTime": "junk"}, "junk"]
        self.assertIsNone(sdclip.plan_window(files, AT))


def packet(msg, payload, session=7, version=1):
    return motiond._DVRIP_HEADER.pack(255, version, session, 0, msg, len(payload)) + payload


class PacketReaderTests(unittest.TestCase):
    def test_finds_the_next_packet_after_a_bad_length(self):
        left, right = socket.socketpair()
        try:
            right.sendall(packet(1426, b"first") + b"\x57\xd5" * 700 + packet(1426, b"second") + packet(1426, b""))
            reader = sdclip.PacketReader(left, 7)
            self.assertEqual(reader.packet(), (1426, b"first"))
            self.assertEqual(reader.packet(), (1426, b"second"))
            self.assertEqual(reader.packet(), (1426, b""))
            self.assertEqual(reader.resyncs, 1)
        finally:
            left.close()
            right.close()


def make_hevc_stream(seconds=2, fps=12):
    """A real HEVC elementary stream wrapped in XM frames with A-law audio, or None without libx265."""
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "s.hevc"
        try:
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i",
                            f"testsrc=size=64x64:rate={fps}", "-t", str(seconds), "-c:v", "libx265",
                            "-x265-params", f"aud=1:repeat-headers=1:keyint={fps}:log-level=none",
                            "-f", "hevc", str(out)], check=True, capture_output=True, timeout=60)
        except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
            return None
        data = out.read_bytes()
    units = [u for u in data.split(b"\x00\x00\x00\x01\x46\x01") if u]
    stream = bytearray()
    for unit in units:
        unit = b"\x00\x00\x00\x01\x46\x01" + unit
        key = b"\x00\x00\x01\x40\x01" in unit  # carries a VPS: a key frame
        stream += xm(sdclip.VIDEO_I if key else sdclip.VIDEO_P, unit, kind=3, fps=fps)
        stream += xm(sdclip.AUDIO, b"\xd5" * (8000 // fps), kind=sdclip.G711A)
    return bytes(stream), len(units)


class FakeCamera:
    """Speaks just enough DVRIP: login, file query, playback claim/download/stop."""

    def __init__(self, stream=b"", files=None, refuse=False, stall_after=None):
        self.stream, self.files, self.refuse, self.stall_after = stream, files or [], refuse, stall_after
        self.logins, self.claims, self.stops = 0, 0, 0
        self.server = socket.socket()
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(4)
        self.port = self.server.getsockname()[1]
        self.done = threading.Event()
        threading.Thread(target=self.serve, daemon=True).start()

    @staticmethod
    def body(data):
        return json.dumps(data).encode() + b"\x0a\x00"

    def serve(self):
        while not self.done.is_set():
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            try:
                self.handle(conn)
            except OSError:
                pass
            finally:
                conn.close()

    def handle(self, conn):
        client = motiond.DvripClient("127.0.0.1", self.port, "", "")
        client.sock = conn
        conn.settimeout(5)
        while True:
            msg, data = client.recv()
            request = motiond.dvrip_json(data)
            if msg == motiond.DVRIP_LOGIN:
                self.logins += 1
                ret = 205 if self.refuse else 100
                conn.sendall(packet(1001, self.body({"Ret": ret, "SessionID": "0x00000007"}), version=0))
                if self.refuse:
                    return
            elif msg == sdclip.FILE_QUERY:
                conn.sendall(packet(1441, self.body({"Ret": 100, "OPFileQuery": self.files})))
            elif msg == sdclip.PLAYBACK_CLAIM:
                self.claims += 1
                conn.sendall(packet(1425, self.body({"Ret": 100})))
            elif msg == sdclip.PLAYBACK and request["OPPlayBack"]["Action"] == "DownloadStart":
                chunks = [self.stream[i:i + 4096] for i in range(0, len(self.stream), 4096)]
                for number, chunk in enumerate(chunks):
                    if self.stall_after is not None and number == self.stall_after:
                        break
                    conn.sendall(packet(1426, chunk))
                    if number == 3:
                        conn.sendall(b"\x57\xd5" * 50)  # a camera glitch the reader must survive
                else:
                    conn.sendall(packet(1426, b""))
            elif msg == sdclip.PLAYBACK:
                self.stops += 1
                conn.sendall(packet(1421, self.body({"Ret": 100})))
                return

    def close(self):
        self.done.set()
        self.server.close()


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "needs ffmpeg")
class FetchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        made = make_hevc_stream()
        if not made:
            raise unittest.SkipTest("ffmpeg has no libx265")
        cls.stream, cls.frames = made

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.config, self.cache = base / "config", base / "cache"
        self.config.mkdir()
        self.camera = None

    def tearDown(self):
        if self.camera:
            self.camera.close()
        self.tmp.cleanup()

    def start(self, **kwargs):
        self.camera = FakeCamera(**kwargs)
        (self.config / "config.json").write_text(json.dumps({"version": 2, "selectedId": "c2", "cameras": [
            {"id": "c2", "name": "Back / yard", "url": "rtsp://127.0.0.1:8554/cam", "username": "", "password": ""},
            {"id": "c3", "name": "Plain", "url": "rtsp://192.0.2.4:554/s", "username": "", "password": ""}]}))
        (self.config / motiond.BRIDGE_CONFIG).write_text(json.dumps({"streams": {
            "cam": f"dvrip://admin:pw@127.0.0.1:{self.camera.port}?channel=0&subtype=0"}}))

    def fetch(self, camera_id="c2"):
        return sdclip.fetch_clip(self.config, camera_id, AT, root=self.cache)

    def recording(self):
        return [entry(AT - timedelta(seconds=30), AT + timedelta(seconds=30))]

    def test_clip_end_to_end_then_from_cache(self):
        self.start(stream=self.stream, files=self.recording())
        result = self.fetch()
        self.assertTrue(result["ok"])
        self.assertFalse(result["cached"] or result["partial"])
        clip = Path(result["path"])
        probe = json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                                           "stream=codec_name,codec_tag_string:format=duration", "-of", "json", str(clip)],
                                          capture_output=True, text=True).stdout)
        codecs = sorted(s["codec_name"] for s in probe["streams"])
        self.assertEqual(codecs, ["aac", "hevc"])
        self.assertIn("hvc1", [s.get("codec_tag_string") for s in probe["streams"]])
        self.assertAlmostEqual(float(probe["format"]["duration"]), self.frames / 12, delta=0.3)
        self.assertEqual(oct(clip.stat().st_mode & 0o777), "0o600")
        self.assertEqual(oct(clip.parent.stat().st_mode & 0o777), "0o700")
        self.assertEqual(sorted(p.name for p in clip.parent.iterdir()), [".lock", clip.name], "no leftovers")
        self.assertEqual((self.camera.claims, self.camera.stops), (1, 1), "download stopped")
        again = self.fetch()
        self.assertTrue(again["cached"])
        self.assertEqual(self.camera.logins, 1, "cached clip needs no second login")

    def test_refused_login_is_tried_once(self):
        self.start(stream=self.stream, files=self.recording(), refuse=True)
        with self.assertRaises(sdclip.ClipError) as caught:
            self.fetch()
        self.assertEqual(caught.exception.code, "login")
        self.assertEqual(self.camera.logins, 1)

    def test_gap_on_the_card(self):
        self.start(stream=self.stream, files=[])
        with self.assertRaises(sdclip.ClipError) as caught:
            self.fetch()
        self.assertEqual(caught.exception.code, "no-recording")
        self.assertEqual(self.camera.claims, 0)

    def test_camera_without_dvrip_is_unsupported(self):
        self.start()
        with self.assertRaises(sdclip.ClipError) as caught:
            self.fetch("c3")
        self.assertEqual(caught.exception.code, "unsupported")
        self.assertEqual(self.camera.logins, 0)

    def test_stalled_camera_gives_a_partial_clip(self):
        self.start(stream=self.stream, files=self.recording(), stall_after=4)
        with mock.patch.object(sdclip, "PACKET_TIMEOUT_SEC", 0.5):
            result = self.fetch()
        self.assertTrue(result["ok"] and result["partial"])
        self.assertEqual(self.camera.stops, 1, "download stopped even after a stall")

    def test_second_fetch_while_one_runs_is_busy(self):
        self.start(stream=self.stream, files=self.recording())
        folder = self.cache / "c2"
        folder.mkdir(parents=True)
        import fcntl
        with open(folder / ".lock", "a") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            with self.assertRaises(sdclip.ClipError) as caught:
                self.fetch()
        self.assertEqual(caught.exception.code, "busy")
        self.assertEqual(self.camera.logins, 0)


class CacheAndSaveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "clips"
        (self.root / "cam").mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def clip(self, name, size=10, age=0):
        path = self.root / "cam" / name
        path.write_bytes(b"x" * size)
        then = time.time() - age
        os.utime(path, (then, then))
        return path

    def test_prune_by_age_size_and_stale_parts(self):
        old = self.clip("old.mp4", age=sdclip.CACHE_MAX_AGE_SEC + 10)
        part = self.clip("x.video.part", age=sdclip.PART_MAX_AGE_SEC + 10)
        fresh_part = self.clip("y.video.part")
        a, b = self.clip("a.mp4", 600, age=20), self.clip("b.mp4", 600, age=10)
        sdclip.prune_cache(self.root, max_bytes=1000)
        self.assertFalse(old.exists() or part.exists() or a.exists())
        self.assertTrue(b.exists() and fresh_part.exists())

    def test_save_copies_privately_and_only_from_the_cache(self):
        source = self.clip("2026-11-15_16-43-15.mp4", 32)
        videos = Path(self.tmp.name) / "Videos"
        saved = sdclip.save_clip(source, "../Back <yard>", root=self.root, videos=videos)
        self.assertEqual(saved, videos / "Cameras" / "Back yard" / source.name)
        self.assertEqual(saved.read_bytes(), source.read_bytes())
        self.assertEqual(oct(saved.stat().st_mode & 0o777), "0o600")
        self.assertEqual(sdclip.save_clip(source, "../Back <yard>", root=self.root, videos=videos), saved,
                         "saving the same clip twice keeps one copy")
        outside = Path(self.tmp.name) / "secret.mp4"
        outside.write_bytes(b"x")
        with self.assertRaises(sdclip.ClipError):
            sdclip.save_clip(outside, "cam", root=self.root, videos=videos)

    def test_cli_rejects_bad_input_without_details(self):
        for argv in (["--camera", "../x", "--at", "2026-11-15 16:43:15"], ["--camera", "c2", "--at", "now"]):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(sdclip.main(argv), 1)
            self.assertEqual(json.loads(out.getvalue()), {"ok": False, "error": "bad-request"})


if __name__ == "__main__":
    unittest.main()
