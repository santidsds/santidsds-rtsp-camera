"""Tests for sdclip.py: XM parsing, window choice, packet recovery, a fake camera end to end."""
import contextlib
import io
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
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
AT_STAMP = (26 << 26) | (11 << 22) | (15 << 17) | (16 << 12) | (43 << 6) | 15


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

    def test_a_wrong_length_does_not_swallow_later_frames(self):
        bad = bytearray(xm(sdclip.VIDEO_P, b"short"))
        bad[4:8] = struct.pack("<I", 40)  # claims 40 bytes; the next frame starts after 5
        raw = xm(sdclip.VIDEO_I, b"key") + bytes(bad) + xm(sdclip.VIDEO_P, b"after") + b"\x00" * 64
        media = sdclip.parse_xm(raw)
        self.assertEqual(bytes(media.video), b"keyafter")

    def test_frames_of_another_codec_are_skipped(self):
        raw = (xm(sdclip.VIDEO_I, b"A", kind=3) + xm(sdclip.VIDEO_P, b"a") + xm(sdclip.VIDEO_I, b"B", kind=2)
               + xm(sdclip.VIDEO_P, b"b") + xm(sdclip.VIDEO_I, b"C", kind=3) + xm(sdclip.VIDEO_P, b"c"))
        self.assertEqual(bytes(sdclip.parse_xm(raw).video), b"AaCc")

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


class StreamingPartsTests(unittest.TestCase):
    def test_split_in_pieces_matches_split_at_once(self):
        raw = b"junk" + b"".join(xm(sdclip.VIDEO_I if i % 5 == 0 else sdclip.VIDEO_P, bytes([i]) * (50 + i))
                                 + xm(sdclip.AUDIO, b"\xd5" * 40, kind=sdclip.G711A) for i in range(30))
        whole, _ = sdclip.split_frames(raw)
        pieces, pending = [], bytearray()
        for start in range(0, len(raw), 37):
            pending += raw[start:start + 37]
            frames, used = sdclip.split_frames(bytes(pending), final=False)
            pieces += frames
            del pending[:used]
        frames, _ = sdclip.split_frames(bytes(pending), final=True)
        pieces += frames
        self.assertEqual([(f.marker, f.payload) for f in pieces], [(f.marker, f.payload) for f in whole])
        self.assertEqual(len(whole), 60)

    def test_ts_writer_output_is_valid_and_timed(self):
        if not shutil.which("ffprobe"):
            self.skipTest("needs ffprobe")
        made = make_hevc_stream(seconds=2)
        if not made:
            self.skipTest("ffmpeg has no libx265")
        frames, _ = sdclip.split_frames(made[0])
        writer, ts, index = sdclip.TsVideoWriter("hevc"), bytearray(), 0
        for frame in frames:
            if frame.marker in (sdclip.VIDEO_I, sdclip.VIDEO_P):
                ts += writer.frame(frame.payload, index / 12)
                index += 1
        self.assertEqual(len(ts) % 188, 0)
        with tempfile.NamedTemporaryFile(suffix=".ts") as out:
            out.write(ts)
            out.flush()
            probe = json.loads(subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-show_entries",
                                               "stream=codec_name,nb_read_frames:format=duration", "-of", "json", out.name],
                                              capture_output=True, text=True).stdout)
        self.assertEqual(probe["streams"][0]["codec_name"], "hevc")
        self.assertEqual(int(probe["streams"][0]["nb_read_frames"]), index)
        self.assertAlmostEqual(float(probe["format"]["duration"]), index / 12, delta=0.1)

    def test_day_index_merges_ranges_and_lists_motion(self):
        day = AT.date()
        files = [entry(datetime(2026, 11, 14, 23, 58), datetime(2026, 11, 15, 0, 3)),
                 entry(datetime(2026, 11, 15, 0, 3), datetime(2026, 11, 15, 0, 8)),
                 entry(datetime(2026, 11, 15, 0, 8, 1), datetime(2026, 11, 15, 0, 8, 30), "M"),
                 entry(datetime(2026, 11, 15, 9, 0), datetime(2026, 11, 15, 9, 5)),
                 {"BeginTime": "bad"}]
        self.assertEqual(sdclip.day_index(files, day), {
            "ranges": [["00:00:00", "00:08:30"], ["09:00:00", "09:05:00"]],
            "motion": [["00:08:01", "00:08:30"]]})

    def test_playback_stops_at_a_gap_in_the_recording(self):
        files = [entry(AT - timedelta(minutes=5), AT + timedelta(minutes=1)),
                 entry(AT + timedelta(minutes=1, seconds=1), AT + timedelta(minutes=6), "M"),
                 entry(AT + timedelta(minutes=20), AT + timedelta(minutes=25))]
        self.assertEqual(sdclip.recorded_until(files, AT), AT + timedelta(minutes=6))
        self.assertEqual(sdclip.recorded_until(files, AT + timedelta(minutes=21)), AT + timedelta(minutes=25))

    def test_playback_starts_at_the_moment_or_the_next_recording(self):
        files = [entry(AT - timedelta(minutes=5), AT - timedelta(minutes=1)),
                 entry(AT + timedelta(minutes=10), AT + timedelta(minutes=15))]
        self.assertEqual(sdclip.plan_playback(files, AT - timedelta(minutes=2)), AT - timedelta(minutes=2))
        self.assertEqual(sdclip.plan_playback(files, AT), AT + timedelta(minutes=10))
        self.assertIsNone(sdclip.plan_playback(files, AT + timedelta(hours=1)))


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
    def test_an_over_long_length_is_cut_at_the_next_header(self):
        left, right = socket.socketpair()
        try:
            liar = motiond._DVRIP_HEADER.pack(255, 1, 7, 0, 1426, 40000) + b"real" * 25
            right.sendall(liar + packet(1426, b"second") + packet(1426, b"z" * 40000) + packet(1426, b""))
            reader = sdclip.PacketReader(left, 7)
            self.assertEqual(reader.packet(), (1426, b"real" * 25))
            self.assertEqual(reader.packet(), (1426, b"second"))
            self.assertEqual(reader.packet(), (1426, b"z" * 40000))
            self.assertEqual(reader.packet(), (1426, b""))
        finally:
            left.close()
            right.close()

    def test_reads_stop_at_the_deadline(self):
        left, right = socket.socketpair()
        try:
            reader = sdclip.PacketReader(left, 7)
            reader.deadline = time.monotonic() + 0.3
            began = time.monotonic()
            with self.assertRaises(TimeoutError):
                reader.packet()
            self.assertLess(time.monotonic() - began, 2)
        finally:
            left.close()
            right.close()

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
        stream += xm(sdclip.VIDEO_I if key else sdclip.VIDEO_P, unit, kind=3, fps=fps, stamp=AT_STAMP)
        stream += xm(sdclip.AUDIO, b"\xd5" * (8000 // fps), kind=sdclip.G711A)
    return bytes(stream), len(units)


class FakeCamera:
    """Speaks just enough DVRIP: login, file query, playback claim/download/stop."""

    def __init__(self, stream=b"", files=None, refuse=False, stall_after=None, refuse_code=205):
        self.stream, self.files, self.refuse, self.stall_after = stream, files or [], refuse, stall_after
        self.refuse_code = refuse_code
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
                ret = self.refuse_code if self.refuse else 100
                conn.sendall(packet(1001, self.body({"Ret": ret, "SessionID": "0x00000007"}), version=0))
                if self.refuse:
                    return
            elif msg == 1020:
                conn.sendall(packet(1021, self.body({"Ret": 100, "StorageInfo": [{"Partition": [
                    {"OldStartTime": "2026-11-13 08:00:00", "NewEndTime": "2026-11-15 16:50:00"},
                    {"OldStartTime": "0000-00-00 00:00:00", "NewEndTime": "0000-00-00 00:00:00"}]}]})))
            elif msg == motiond.DVRIP_KEEPALIVE:
                conn.sendall(packet(1007, self.body({"Ret": 100})))
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

    def test_index_lists_days_and_the_day(self):
        self.start(files=self.recording() + [entry(AT, AT + timedelta(seconds=20), "M")])
        result = sdclip.recording_index(self.config, "c2", AT.date(), root=self.cache)
        self.assertEqual(result["days"], ["2026-11-15", "2026-11-14", "2026-11-13"])
        self.assertEqual(result["date"], "2026-11-15")
        self.assertEqual(result["ranges"], [["16:42:45", "16:43:45"]])
        self.assertEqual(result["motion"], [["16:43:15", "16:43:35"]])

    def test_playback_streams_everything_with_audio_and_stops_the_camera(self):
        self.start(stream=self.stream, files=self.recording())
        said = []
        result = {}

        def run():
            result["value"] = sdclip.stream_playback(self.config, "c2", AT, said.append, root=self.cache)
        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        deadline = time.time() + 10
        while not said and time.time() < deadline:
            time.sleep(0.05)
        url = said[0]["url"]
        self.assertRegex(url, r"^http://127\.0\.0\.1:\d+/[A-Za-z0-9_-]{20,}\.ts$")
        self.assertEqual(said[0]["start"], AT.strftime(sdclip.TIME_FORMAT))
        wrong = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                                url.rsplit("/", 1)[0] + "/guess.ts"], capture_output=True, text=True, timeout=10)
        self.assertEqual(wrong.stdout, "404", "only the private token is served")
        probe = subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-show_entries",
                                "stream=codec_type,nb_read_frames", "-of", "json", url],
                               capture_output=True, text=True, timeout=30)
        streams = {s["codec_type"]: s for s in json.loads(probe.stdout)["streams"]}
        self.assertEqual(int(streams["video"]["nb_read_frames"]), self.frames)
        self.assertIn("audio", streams)
        thread.join(10)
        self.assertTrue(result["value"]["ended"])
        self.assertEqual(said[1], {"first": AT.strftime(sdclip.TIME_FORMAT)}, "the first frame's clock time")
        self.assertEqual((self.camera.claims, self.camera.stops), (1, 1))
        self.assertFalse(any(p.suffix == ".mp4" for p in self.cache.rglob("*")), "nothing written to disk")

    def test_refused_login_is_tried_once_then_cools_down(self):
        self.start(stream=self.stream, files=self.recording(), refuse=True)
        for _ in range(2):
            with self.assertRaises(sdclip.ClipError) as caught:
                self.fetch()
            self.assertEqual(caught.exception.code, "login")
        self.assertEqual(self.camera.logins, 1, "a second tap doesn't add to the camera's failed logins")
        with mock.patch.dict(os.environ, {"XDG_CACHE_HOME": str(self.cache.parent / "xdg-cache")}):
            marker = sdclip.cache_root() / "c2" / sdclip.LOGIN_REFUSED
            marker.parent.mkdir(parents=True)
            marker.touch()
            motiond.cmd_set_login(self.config, "c3", ask=lambda _: "admin", ask_secret=lambda _: "pw",
                                  client_class=AcceptingClient)
            self.assertTrue(marker.exists(), "another camera's login leaves this cooldown alone")
            motiond.cmd_set_login(self.config, "c2", ask=lambda _: "admin", ask_secret=lambda _: "pw",
                                  client_class=AcceptingClient)
            self.assertTrue(marker.exists(), "bridge cameras keep their login; nothing saved")

    def test_gap_on_the_card(self):
        self.start(stream=self.stream, files=[])
        with self.assertRaises(sdclip.ClipError) as caught:
            self.fetch()
        self.assertEqual(caught.exception.code, "no-recording")
        self.assertEqual(self.camera.claims, 0)

    def test_a_busy_account_is_not_a_password_refusal(self):
        self.start(stream=self.stream, files=self.recording(), refuse=True, refuse_code=207)
        with self.assertRaises(sdclip.ClipError) as caught:
            self.fetch()
        self.assertEqual(caught.exception.code, "login")
        self.assertFalse((self.cache / "c2" / sdclip.LOGIN_REFUSED).exists(), "no cooldown for 'logged in elsewhere'")

    def test_camera_without_dvrip_is_unsupported(self):
        self.start()
        with self.assertRaises(sdclip.ClipError) as caught:
            self.fetch("c3")
        self.assertEqual(caught.exception.code, "unsupported")
        self.assertEqual(self.camera.logins, 0)

    def test_stalled_camera_gives_a_partial_clip_that_is_not_reused(self):
        self.start(stream=self.stream, files=self.recording(), stall_after=4)
        with mock.patch.object(sdclip, "PACKET_TIMEOUT_SEC", 0.5):
            result = self.fetch()
            self.assertTrue(result["ok"] and result["partial"])
            self.assertTrue(result["path"].endswith(".partial.mp4"))
            self.assertEqual(self.camera.stops, 1, "download stopped even after a stall")
            again = self.fetch()
        self.assertFalse(again["cached"])
        self.assertEqual(self.camera.logins, 2, "a partial clip is fetched again, not reused")

    def test_a_still_from_moments_ago_is_not_cached_as_final(self):
        self.start(stream=self.stream, files=[entry(datetime.now() - timedelta(minutes=1),
                                                    datetime.now() + timedelta(minutes=1))])
        result = sdclip.fetch_clip(self.config, "c2", datetime.now().replace(microsecond=0), root=self.cache)
        self.assertTrue(result["ok"] and result["path"].endswith(".partial.mp4"),
                        "the recording is still being written, so ask the camera again next time")

    def test_download_is_paced(self):
        self.start(stream=self.stream, files=self.recording())
        began = time.monotonic()
        with mock.patch.object(sdclip, "RATE_LIMIT_BYTES", 16 * 1024):
            self.assertTrue(self.fetch()["ok"])
        self.assertGreater(time.monotonic() - began, len(self.stream) / (16 * 1024) * 0.8)

    def test_cancelling_tells_the_camera_to_stop(self):
        self.start(stream=self.stream, files=self.recording(), stall_after=2)
        env = dict(os.environ, XDG_CONFIG_HOME=str(self.config.parent / "xdg"), XDG_CACHE_HOME=str(self.cache))
        (self.config.parent / "xdg").mkdir()
        (self.config.parent / "xdg" / "rtsp-camera").symlink_to(self.config)
        process = subprocess.Popen([sys.executable, str(Path(sdclip.__file__)), "--camera", "c2",
                                    "--at", AT.strftime(sdclip.TIME_FORMAT)], env=env,
                                   stdout=subprocess.PIPE, text=True)
        deadline = time.time() + 10
        while self.camera.claims == 0 and time.time() < deadline:
            time.sleep(0.05)
        time.sleep(0.3)
        process.terminate()
        out, _ = process.communicate(timeout=10)
        self.assertEqual(json.loads(out.strip().splitlines()[-1]), {"ok": False, "error": "cancelled"})
        deadline = time.time() + 5
        while self.camera.stops == 0 and time.time() < deadline:
            time.sleep(0.05)
        self.assertEqual(self.camera.stops, 1)
        self.assertEqual([p.name for p in (self.cache / "rtsp-camera" / "clips" / "c2").iterdir()], [".lock"],
                         "no partial files left")

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


class AcceptingClient:
    def __init__(self, *args):
        pass

    def connect(self):
        pass

    def close(self):
        pass


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
