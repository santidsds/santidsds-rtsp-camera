#!/usr/bin/env python3
"""Fetch a short clip from a camera's SD card and turn it into an MP4.

The Motion gallery's "Play clip" calls this for one still. It asks the camera
(over DVRIP, the protocol of XMeye/iCSee cameras) for the recording around that
moment, downloads only that window, and remuxes it without re-encoding the
video. Nothing is synced in the background: clips live in a private cache that
prunes itself, and --save copies one to your Videos folder.

  sdclip.py --camera ID --at "YYYY-MM-DD HH:MM:SS"
      prints {"progress": bytes} lines, then {"ok": true, "path": ..., ...}
      or {"ok": false, "error": "<code>"}
  sdclip.py --save PATH --camera ID
      {"ok": true, "path": "<saved copy>"}

Error codes: unsupported, login, unreachable, no-recording, timeout, empty,
busy, ffmpeg, bad-request, cancelled, failed.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

import motiond

BEFORE_SEC = 4            # lead-in before the still (covers a key frame)
AFTER_SEC = 20            # minimum length after the still
MAX_SPAN_SEC = 90         # longest clip
MAX_BYTES = 64 * 1024 * 1024
DEADLINE_SEC = 75         # whole download
PACKET_TIMEOUT_SEC = 10   # one silent gap from the camera
# Gentle on weak cameras: an X2C-WQ on Wi-Fi choked and rebooted when flooded.
# ~3x the recording bitrate, so a 25 s clip takes about 8 s.
RATE_LIMIT_BYTES = 320 * 1024   # per second
RECEIVE_BUFFER = 64 * 1024
CACHE_MAX_AGE_SEC = 24 * 3600
CACHE_MAX_BYTES = 400 * 1024 * 1024
PART_MAX_AGE_SEC = 3600
TIME_FORMAT = "%Y-%m-%d %H:%M:%S"
FILE_TIME_FORMAT = "%Y-%m-%d_%H-%M-%S"
OK_CODES = (100, 150, 515)

FILE_QUERY = 1440
PLAYBACK = 1420
PLAYBACK_CLAIM = 1424
PLAYBACK_DATA = 1426

# XM media framing inside recordings: 00 00 01 + marker byte.
VIDEO_I, VIDEO_P, AUDIO, INFO, PICTURE = 0xFC, 0xFD, 0xFA, 0xF9, 0xFE
MARKERS = {VIDEO_I, VIDEO_P, AUDIO, INFO, PICTURE}
CODECS = {2: "h264", 3: "hevc"}
G711A = 0x0E
AUDIO_RATE = 8000
MAX_VIDEO_FRAME = 4 * 1024 * 1024
MAX_AUDIO_FRAME = 8192


class ClipError(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


# --- XM stream parsing (pure) --------------------------------------------------

@dataclass
class XmMedia:
    codec: str = ""
    fps: int = 0
    width: int = 0
    height: int = 0
    frames: int = 0
    first_time: datetime | None = None
    video: bytearray = field(default_factory=bytearray)
    audio: bytearray = field(default_factory=bytearray)


def xm_time(value: int) -> datetime | None:
    try:
        return datetime(((value >> 26) & 0x3F) + 2000, (value >> 22) & 0xF, (value >> 17) & 0x1F,
                        (value >> 12) & 0x1F, (value >> 6) & 0x3F, value & 0x3F)
    except ValueError:
        return None


def _next_marker(raw: bytes, start: int) -> int:
    pos = raw.find(b"\x00\x00\x01", start)
    while pos != -1 and (pos + 3 >= len(raw) or raw[pos + 3] not in MARKERS):
        pos = raw.find(b"\x00\x00\x01", pos + 1)
    return pos


def parse_xm(raw: bytes) -> XmMedia:
    """Split an XM recording into an Annex-B video stream and G.711 A-law audio.

    Everything before the first key frame is dropped (P-frames without their
    parameter sets cannot be decoded); garbage is skipped by searching for the
    next frame marker; a truncated last frame ends the stream.
    """
    media = XmMedia()
    pos, size, started = 0, len(raw), False
    while pos + 8 <= size:
        if raw[pos:pos + 3] != b"\x00\x00\x01" or raw[pos + 3] not in MARKERS:
            pos = _next_marker(raw, pos + 1)
            if pos < 0:
                break
            continue
        marker = raw[pos + 3]
        kind = 0
        if marker in (VIDEO_I, PICTURE):
            if pos + 16 > size:
                break
            kind, fps, width, height, stamp, length = struct.unpack_from("<BBBBII", raw, pos + 4)
            header, limit = 16, MAX_VIDEO_FRAME
        elif marker == VIDEO_P:
            (length,) = struct.unpack_from("<I", raw, pos + 4)
            header, limit = 8, MAX_VIDEO_FRAME
        else:
            kind, _rate, length = struct.unpack_from("<BBH", raw, pos + 4)
            header, limit = 8, MAX_AUDIO_FRAME
        if length > limit or (marker == VIDEO_I and kind not in CODECS):
            pos = _next_marker(raw, pos + 1)  # a false marker inside other data
            if pos < 0:
                break
            continue
        end = pos + header + length
        if end > size:
            break  # truncated tail
        payload = raw[pos + header:end]
        if marker == VIDEO_I and (not media.codec or media.codec == CODECS[kind]):
            if not started:
                media.codec, media.fps = CODECS[kind], fps
                media.width, media.height = width * 8, height * 8
                media.first_time = xm_time(stamp)
            started = True
        if started:
            if marker in (VIDEO_I, VIDEO_P):
                media.video += payload
                media.frames += 1
            elif marker == AUDIO and kind == G711A:
                media.audio += payload
        pos = end
    return media


def effective_fps(media: XmMedia) -> float:
    """The header's frame rate, unless the audio clock says otherwise (night mode lowers fps)."""
    fps = float(media.fps or 0)
    audio_seconds = len(media.audio) / AUDIO_RATE
    if media.frames and audio_seconds >= 2:
        measured = media.frames / audio_seconds
        if not fps or abs(measured - fps) / fps > 0.08:
            fps = measured
    return min(60.0, max(1.0, fps or 12.0))


def write_mp4(media: XmMedia, out: Path, ffmpeg: str = "ffmpeg") -> float:
    """Remux to MP4 (video copied, audio to AAC). Returns the duration in seconds."""
    if not media.codec or media.frames < 2:
        raise ClipError("empty")
    fps = effective_fps(media)
    video = out.with_name(out.stem + ".video.part")
    audio = out.with_name(out.stem + ".alaw.part")
    temporary = out.with_name(out.stem + ".mp4.part")
    try:
        video.write_bytes(media.video)
        command = [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                   "-f", media.codec, "-framerate", f"{fps:.3f}", "-i", str(video)]
        if media.audio:
            audio.write_bytes(media.audio)
            command += ["-f", "alaw", "-ar", str(AUDIO_RATE), "-ac", "1", "-i", str(audio)]
        command += ["-map", "0:v:0"] + (["-map", "1:a:0"] if media.audio else []) + ["-c:v", "copy"]
        if media.codec == "hevc":
            command += ["-tag:v", "hvc1"]
        if media.audio:
            command += ["-c:a", "aac", "-b:a", "48k"]
        command += ["-movflags", "+faststart", "-f", "mp4", str(temporary)]
        try:
            result = subprocess.run(command, capture_output=True, timeout=90)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ClipError("ffmpeg") from error
        if result.returncode or not temporary.exists() or temporary.stat().st_size == 0:
            raise ClipError("ffmpeg")
        os.replace(temporary, out)
    finally:
        for path in (video, audio, temporary):
            path.unlink(missing_ok=True)
    return media.frames / fps


# --- picking the window (pure) ---------------------------------------------------

def parse_time(value) -> datetime | None:
    try:
        return datetime.strptime(str(value), TIME_FORMAT)
    except ValueError:
        return None


def plan_window(files: list, at: datetime) -> tuple[datetime, datetime] | None:
    """Clip window around a still, or None if the card has no recording then.

    A few seconds before the still, at least AFTER_SEC after it, extended to
    the end of the motion recording ([M] file) it falls in, capped at
    MAX_SPAN_SEC.
    """
    covering = []
    for entry in files:
        if not isinstance(entry, dict):
            continue
        begin, end = parse_time(entry.get("BeginTime")), parse_time(entry.get("EndTime"))
        if not begin or not end:
            continue
        if begin - timedelta(seconds=5) <= at <= end + timedelta(seconds=2):
            covering.append((begin, end, "[M]" in str(entry.get("FileName", ""))))
    if not covering:
        return None
    start = at - timedelta(seconds=BEFORE_SEC)
    finish = at + timedelta(seconds=AFTER_SEC)
    for _begin, end, motion in covering:
        if motion:
            finish = max(finish, end + timedelta(seconds=2))
    return start, min(finish, start + timedelta(seconds=MAX_SPAN_SEC))


# --- DVRIP transfer ----------------------------------------------------------------

class PacketReader:
    """Reads DVRIP packets from a logged-in socket, re-finding packet starts if a
    camera sends a length that doesn't match its data (seen on an X2C-WQ)."""

    MAX_RESYNC = 2 * 1024 * 1024

    def __init__(self, sock: socket.socket, session: int):
        self.sock = sock
        self.buffer = bytearray()
        tail = b"\x00\x00" + struct.pack("<I", session)
        self.signatures = (b"\xff\x00" + tail, b"\xff\x01" + tail)
        self.resyncs = 0

    def _fill(self, size: int):
        while len(self.buffer) < size:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("camera closed the connection")
            self.buffer += chunk

    def _resync(self):
        skipped = 0
        while True:
            hits = [i for i in (self.buffer.find(s, 1) for s in self.signatures) if i > 0]
            if hits:
                del self.buffer[:min(hits)]
                self.resyncs += 1
                return
            keep = len(self.signatures[0]) - 1
            skipped += max(0, len(self.buffer) - keep)
            del self.buffer[:max(0, len(self.buffer) - keep)]
            if skipped > self.MAX_RESYNC:
                raise ConnectionError("lost the packet stream")
            self._fill(len(self.buffer) + 1)

    def packet(self) -> tuple[int, bytes]:
        while True:
            self._fill(motiond._DVRIP_HEADER.size)
            head, version, _session, _seq, msg, length = motiond._DVRIP_HEADER.unpack_from(self.buffer, 0)
            if head == 255 and version <= 1 and length <= motiond.DVRIP_MAX_PACKET:
                break
            self._resync()
        total = motiond._DVRIP_HEADER.size + length
        self._fill(total)
        payload = bytes(self.buffer[motiond._DVRIP_HEADER.size:total])
        del self.buffer[:total]
        return msg, payload

    def reply(self, msg_id: int, limit: int = 64) -> dict:
        for _ in range(limit):
            msg, payload = self.packet()
            if msg == msg_id:
                return motiond.dvrip_json(payload)
        raise ConnectionError("reply missing")


def query_files(client, reader: PacketReader, begin: datetime, end: datetime, pages: int = 8) -> list:
    files, start = [], begin.strftime(TIME_FORMAT)
    for _ in range(pages):
        client.send(FILE_QUERY, {"Name": "OPFileQuery", "SessionID": client.session_id, "OPFileQuery": {
            "BeginTime": start, "EndTime": end.strftime(TIME_FORMAT), "Channel": 0,
            "DriverTypeMask": "0x0000FFFF", "Event": "*", "StreamType": "0x00000000", "Type": "h264"}})
        reply = reader.reply(FILE_QUERY + 1)
        page = reply.get("OPFileQuery") if reply.get("Ret") == 100 else []
        page = [entry for entry in page if isinstance(entry, dict)] if isinstance(page, list) else []
        fresh = [entry for entry in page if entry not in files]
        files += fresh
        if len(page) < 64 or not fresh or not page[-1].get("BeginTime"):
            break
        start = page[-1]["BeginTime"]
    return files


def download(client, reader: PacketReader, start: datetime, end: datetime,
             deadline: float, max_bytes: int = MAX_BYTES, progress=None) -> tuple[bytes, bool]:
    """Download a time window. Returns (data, complete); a slow camera yields a partial clip."""
    params = {"PlayMode": "ByTime", "FileName": "", "StreamType": 0, "Value": 0, "TransMode": "TCP", "Channel": 0}

    def body(action):
        return {"Name": "OPPlayBack", "SessionID": client.session_id, "OPPlayBack": {
            "Action": action, "Parameter": params,
            "StartTime": start.strftime(TIME_FORMAT), "EndTime": end.strftime(TIME_FORMAT)}}

    client.send(PLAYBACK_CLAIM, body("Claim"))
    if reader.reply(PLAYBACK_CLAIM + 1).get("Ret") not in OK_CODES:
        raise ClipError("no-recording")
    data, complete, reported = bytearray(), False, 0
    client.sock.settimeout(PACKET_TIMEOUT_SEC)
    client.send(PLAYBACK, body("DownloadStart"))
    began = time.monotonic()
    try:
        while time.monotonic() < deadline and len(data) < max_bytes:
            msg, payload = reader.packet()
            if msg == PLAYBACK_DATA:
                if not payload:
                    complete = True
                    break
                data += payload
                if progress and len(data) - reported >= 256 * 1024:
                    reported = len(data)
                    progress(reported)
                ahead = len(data) / RATE_LIMIT_BYTES - (time.monotonic() - began)
                if ahead > 0:
                    time.sleep(min(ahead, max(0.0, deadline - time.monotonic())))
            elif msg == PLAYBACK + 1 and payload[:1] == b"{":
                if motiond.dvrip_json(payload).get("Ret") not in OK_CODES:
                    raise ClipError("no-recording")
    except (OSError, ConnectionError):
        if not data:
            raise ClipError("timeout") from None
    finally:
        try:
            client.sock.settimeout(5)
            client.send(PLAYBACK, body("DownloadStop"))
        except OSError:
            pass
    if not data and not complete:
        raise ClipError("timeout")
    return bytes(data), complete


# --- cache, save, orchestration ---------------------------------------------------

def cache_root() -> Path:
    base = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    return base / "rtsp-camera" / "clips"


def prune_cache(root: Path, now: float | None = None, max_age: float = CACHE_MAX_AGE_SEC,
                max_bytes: int = CACHE_MAX_BYTES) -> int:
    now = time.time() if now is None else now
    removed = 0
    clips = []
    for path in root.glob("*/*"):
        try:
            info = path.stat()
        except OSError:
            continue
        if path.name.endswith(".part"):
            if now - info.st_mtime > PART_MAX_AGE_SEC:
                path.unlink(missing_ok=True)
                removed += 1
        elif path.suffix == ".mp4":
            if now - info.st_mtime > max_age:
                path.unlink(missing_ok=True)
                removed += 1
            else:
                clips.append((info.st_mtime, info.st_size, path))
    total = sum(size for _, size, _ in clips)
    for _mtime, size, path in sorted(clips):
        if total <= max_bytes:
            break
        path.unlink(missing_ok=True)
        total -= size
        removed += 1
    return removed


def fetch_clip(config_dir: Path, camera_id: str, at: datetime, client_class=None, progress=None,
               ffmpeg: str = "ffmpeg", root: Path | None = None) -> dict:
    client_class = client_class or motiond.DvripClient
    root = root or cache_root()
    library = motiond.load_json(config_dir / "config.json", {})
    camera = motiond.find_camera(library if isinstance(library, dict) else {}, camera_id)
    if not camera:
        raise ClipError("bad-request")
    login = motiond.dvrip_login_for(config_dir, camera)
    if not login:
        raise ClipError("unsupported")
    folder = root / camera_id
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    prune_cache(root)
    out = folder / (at.strftime(FILE_TIME_FORMAT) + ".mp4")

    def done(cached, window=None, complete=True, duration=None):
        os.utime(out)
        result = {"ok": True, "path": str(out), "cached": cached, "partial": not complete}
        if window:
            result.update(start=window[0].strftime(TIME_FORMAT), end=window[1].strftime(TIME_FORMAT))
        if duration is not None:
            result["duration"] = round(duration, 1)
        return result

    if out.is_file() and out.stat().st_size > 0:
        return done(True)
    with open(folder / ".lock", "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ClipError("busy") from None
        if out.is_file() and out.stat().st_size > 0:
            return done(True)
        deadline = time.monotonic() + DEADLINE_SEC
        client = client_class(login["host"], login["port"], login["user"], login["password"], timeout=10)
        client.receive_buffer = RECEIVE_BUFFER
        try:
            try:
                client.connect()  # one attempt: failures count toward the camera's lockout
            except motiond.DvripLoginError:
                raise ClipError("login") from None
            except OSError:
                raise ClipError("unreachable") from None
            reader = PacketReader(client.sock, client.session)
            files = query_files(client, reader, at - timedelta(minutes=3), at + timedelta(minutes=3))
            window = plan_window(files, at)
            if not window:
                raise ClipError("no-recording")
            raw, complete = download(client, reader, window[0], window[1], deadline, progress=progress)
        except (OSError, ConnectionError):
            raise ClipError("unreachable") from None
        finally:
            client.close()
        duration = write_mp4(parse_xm(raw), out, ffmpeg)
        return done(False, window, complete, duration)


def safe_name(name: str) -> str:
    cleaned = re.sub(r"[^\w .()-]", "", str(name)).strip(" .")
    return cleaned[:60] or "Camera"


def videos_dir() -> Path:
    try:
        out = subprocess.run(["xdg-user-dir", "VIDEOS"], capture_output=True, text=True, timeout=3).stdout.strip()
        if out and Path(out) != Path.home() and Path(out).is_absolute():
            return Path(out)
    except (OSError, subprocess.TimeoutExpired):
        pass
    return Path.home() / "Videos"


def save_clip(path: Path, camera_name: str, root: Path | None = None, videos: Path | None = None) -> Path:
    """Copy a cached clip to Videos/Cameras/<camera>/ (only files from the clip cache)."""
    root = (root or cache_root()).resolve()
    source = Path(path).resolve()
    if root not in source.parents or source.suffix != ".mp4" or not source.is_file():
        raise ClipError("bad-request")
    folder = (videos or videos_dir()) / "Cameras" / safe_name(camera_name)
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    target, number = folder / source.name, 2
    while target.exists():
        if target.stat().st_size == source.stat().st_size and target.read_bytes() == source.read_bytes():
            return target
        target = folder / f"{source.stem} ({number}).mp4"
        number += 1
    temporary = target.with_name(target.name + ".part")
    shutil.copyfile(source, temporary)
    os.chmod(temporary, 0o600)
    os.replace(temporary, target)
    return target


def emit(data: dict):
    print(json.dumps(data), flush=True)


def _cancel(signum, frame):  # noqa: ARG001
    # Unwind normally so the camera is told to stop sending (see download()).
    raise ClipError("cancelled")


def main(argv=None) -> int:
    os.umask(0o077)
    signal.signal(signal.SIGTERM, _cancel)
    signal.signal(signal.SIGINT, _cancel)
    parser = argparse.ArgumentParser(description="Fetch a clip from a camera's SD card.")
    parser.add_argument("--camera", required=True)
    parser.add_argument("--at")
    parser.add_argument("--save")
    args = parser.parse_args(argv)
    config_dir = motiond.base_dirs()[0]
    try:
        if not motiond.valid_camera_id(args.camera):
            raise ClipError("bad-request")
        if args.save:
            library = motiond.load_json(config_dir / "config.json", {})
            camera = motiond.find_camera(library if isinstance(library, dict) else {}, args.camera) or {}
            emit({"ok": True, "path": str(save_clip(Path(args.save), camera.get("name") or "Camera"))})
            return 0
        if not args.at or not re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", args.at):
            raise ClipError("bad-request")
        at = parse_time(args.at)
        if not at:
            raise ClipError("bad-request")
        emit(fetch_clip(config_dir, args.camera, at, progress=lambda n: emit({"progress": n})))
        return 0
    except ClipError as error:
        emit({"ok": False, "error": error.code})
    except Exception as error:  # noqa: BLE001 - never print messages that could carry credentials
        emit({"ok": False, "error": "failed", "detail": type(error).__name__})
    return 1


if __name__ == "__main__":
    sys.exit(main())
