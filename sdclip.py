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
busy, ffmpeg, bad-request, cancelled, failed. After a refused login no new
login is tried for 10 minutes (the camera locks the account after a few).
"""
from __future__ import annotations

import argparse
import fcntl
import queue
import secrets
import threading
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
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import date, datetime, time as daytime, timedelta
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
PLAY_RATE_LIMIT_BYTES = 640 * 1024  # playback follows the player; this caps 4x fast-forward
RECEIVE_BUFFER = 64 * 1024
MAX_DATA_PACKET = 256 * 1024     # cameras send 32 KB playback packets; more means a bad length
LOGIN_COOLDOWN_SEC = 600         # after a refused login, don't try again for a while (lockout)
LOGIN_REFUSED = ".login-refused"
PLAY_SPAN_SEC = 30 * 60          # one playback session; the viewer starts another after it
PLAY_ACCEPT_SEC = 20             # the player must connect within this
PLAY_SEND_TIMEOUT_SEC = 120      # a player paused longer than this ends the session
MAX_DAYS = 60
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


DEBUG = os.environ.get("SDCLIP_DEBUG") == "1"


def debug(*parts):
    if DEBUG:
        print("sdclip:", *parts, file=sys.stderr, flush=True)


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


@dataclass
class XmFrame:
    marker: int
    kind: int
    payload: bytes
    fps: int = 0
    width: int = 0
    height: int = 0
    stamp: int = 0


def split_frames(raw: bytes, final: bool = True) -> tuple[list[XmFrame], int]:
    """Cut XM media framing into frames. Returns (frames, bytes consumed).

    With final=False (a stream still arriving) it stops before a frame it can't
    judge yet, so the caller keeps the rest and calls again with more data.
    Garbage is skipped by searching for the next frame marker. Frames are back
    to back, and video can't contain a frame marker (H.264/H.265 never start a
    unit with those bytes), so a marker inside a frame's claimed span, or none
    where the next frame should start, means its length is wrong.
    """
    frames, pos, size = [], 0, len(raw)

    def skip_from(at):
        nxt = _next_marker(raw, at)
        if nxt >= 0:
            return nxt, False
        return (size if final else max(at, size - 3)), True  # keep a possibly split marker

    while pos + 8 <= size:
        if raw[pos:pos + 3] != b"\x00\x00\x01" or raw[pos + 3] not in MARKERS:
            pos, done = skip_from(pos + 1)
            if done:
                break
            continue
        marker, info = raw[pos + 3], {}
        kind = 0
        if marker in (VIDEO_I, PICTURE):
            if pos + 16 > size:
                break
            kind, fps, width, height, stamp, length = struct.unpack_from("<BBBBII", raw, pos + 4)
            info = {"fps": fps, "width": width * 8, "height": height * 8, "stamp": stamp}
            header, limit = 16, MAX_VIDEO_FRAME
        elif marker == VIDEO_P:
            (length,) = struct.unpack_from("<I", raw, pos + 4)
            header, limit = 8, MAX_VIDEO_FRAME
        else:
            kind, _rate, length = struct.unpack_from("<BBH", raw, pos + 4)
            header, limit = 8, MAX_AUDIO_FRAME
        if length > limit or (marker == VIDEO_I and kind not in CODECS):
            pos, done = skip_from(pos + 1)  # a false marker inside other data
            if done:
                break
            continue
        end = pos + header + length
        if end > size:
            if not final:
                break  # wait for the rest of the frame
            pos, done = skip_from(pos + 1)  # truncated tail, or a wrong length
            if done:
                break
            continue
        inner = _next_marker(raw, pos + header)
        if inner != -1 and inner < end:
            pos, done = skip_from(pos + 1)
            if done:
                break
            continue
        if end + 4 > size:
            if not final:
                break  # need to see where the next frame starts
        elif not (raw[end:end + 3] == b"\x00\x00\x01" and raw[end + 3] in MARKERS):
            if _next_marker(raw, end) != -1:
                pos, done = skip_from(pos + 1)
                if done:
                    break
                continue
            if not final:
                break
        frames.append(XmFrame(marker, kind, raw[pos + header:end], **info))
        pos = end
    return frames, pos


class XmAssembler:
    """Picks the frames that make a clip: from the first key frame on, one codec."""

    def __init__(self, collect: bool = True):
        self.media = XmMedia()
        self.collect = collect
        self.started = False
        self.skipping = False

    def add(self, frame: XmFrame) -> str | None:
        """Returns "video", "audio" or None (dropped)."""
        if frame.marker == VIDEO_I:
            codec = CODECS[frame.kind]
            if not self.media.codec:
                media = self.media
                media.codec, media.fps, media.width, media.height = codec, frame.fps, frame.width, frame.height
                media.first_time = xm_time(frame.stamp)
            self.skipping = codec != self.media.codec  # another stream's frames; skip until ours return
            self.started = self.started or not self.skipping
        if not self.started:
            return None
        if frame.marker in (VIDEO_I, VIDEO_P):
            if self.skipping:
                return None
            self.media.frames += 1
            if self.collect:
                self.media.video += frame.payload
            return "video"
        if frame.marker == AUDIO and frame.kind == G711A:
            if self.collect:
                self.media.audio += frame.payload
            return "audio"
        return None


def parse_xm(raw: bytes) -> XmMedia:
    """Split an XM recording into an Annex-B video stream and G.711 A-law audio.

    Everything before the first key frame is dropped (P-frames without their
    parameter sets cannot be decoded).
    """
    assembler = XmAssembler()
    frames, _ = split_frames(raw, final=True)
    for frame in frames:
        assembler.add(frame)
    return assembler.media


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
        self.deadline = None  # time.monotonic() limit for every read

    def _fill(self, size: int):
        while len(self.buffer) < size:
            if self.deadline is not None:
                remaining = self.deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("clip deadline")
                self.sock.settimeout(min(PACKET_TIMEOUT_SEC, remaining))
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("camera closed the connection")
            self.buffer += chunk

    def _resync(self):
        skipped, start = 0, 1  # the bad header itself sits at 0 on the first pass only
        while True:
            hits = [i for i in (self.buffer.find(s, start) for s in self.signatures) if i >= start]
            start = 0
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

    def _plausible(self, data, offset: int = 0) -> bool:
        head, version, _session, _seq, msg, length = motiond._DVRIP_HEADER.unpack_from(data, offset)
        limit = MAX_DATA_PACKET if msg == PLAYBACK_DATA else motiond.DVRIP_MAX_PACKET
        return head == 255 and version <= 1 and length <= limit

    def _embedded_header(self, payload: bytes) -> int | None:
        """Where a real packet header starts inside a payload whose length was too long."""
        cuts = []
        for signature in self.signatures:
            at = payload.find(signature, 1)
            while at != -1:
                if len(payload) - at < motiond._DVRIP_HEADER.size or self._plausible(payload, at):
                    cuts.append(at)
                    break
                at = payload.find(signature, at + 1)
        return min(cuts) if cuts else None

    def packet(self) -> tuple[int, bytes]:
        while True:
            self._fill(motiond._DVRIP_HEADER.size)
            if self._plausible(self.buffer):
                break
            self._resync()
        _head, _version, _session, _seq, msg, length = motiond._DVRIP_HEADER.unpack_from(self.buffer, 0)
        total = motiond._DVRIP_HEADER.size + length
        self._fill(total)
        payload = bytes(self.buffer[motiond._DVRIP_HEADER.size:total])
        del self.buffer[:total]
        if msg == PLAYBACK_DATA:
            cut = self._embedded_header(payload)
            if cut is not None:  # the length was too long: hand the rest back
                self.buffer[:0] = payload[cut:]
                payload = payload[:cut]
                self.resyncs += 1
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

    data, complete, reported, claimed = bytearray(), False, 0, False
    reader.deadline = deadline
    try:
        claimed = True  # from here on, always tell the camera to stop
        client.send(PLAYBACK_CLAIM, body("Claim"))
        if reader.reply(PLAYBACK_CLAIM + 1).get("Ret") not in OK_CODES:
            raise ClipError("no-recording")
        client.send(PLAYBACK, body("DownloadStart"))
        began = last_alive = time.monotonic()
        alive_every = max(2.0, getattr(client, "alive_interval", 20) / 2)
        while time.monotonic() < deadline and len(data) < max_bytes:
            if time.monotonic() - last_alive > alive_every:
                client.keepalive()  # long downloads must not let the session expire
                last_alive = time.monotonic()
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
        if claimed:
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


def camera_target(config_dir: Path, camera_id: str, root: Path) -> tuple[dict, Path]:
    """The camera's DVRIP login and its private cache folder."""
    library = motiond.load_json(config_dir / "config.json", {})
    camera = motiond.find_camera(library if isinstance(library, dict) else {}, camera_id)
    if not camera:
        raise ClipError("bad-request")
    login = motiond.dvrip_login_for(config_dir, camera)
    if not login:
        raise ClipError("unsupported")
    folder = root / camera_id
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    return login, folder


@contextmanager
def camera_session(login: dict, folder: Path, client_class=None, deadline: float | None = None):
    """One DVRIP login, never retried; after a refusal none for LOGIN_COOLDOWN_SEC."""
    client_class = client_class or motiond.DvripClient
    refused = folder / LOGIN_REFUSED
    try:
        if time.time() - refused.stat().st_mtime < LOGIN_COOLDOWN_SEC:
            raise ClipError("login")  # don't add to the camera's failed-login count
    except FileNotFoundError:
        pass
    client = client_class(login["host"], login["port"], login["user"], login["password"], timeout=10)
    client.receive_buffer = RECEIVE_BUFFER
    try:
        try:
            client.connect()
        except motiond.DvripLoginError:
            refused.touch()
            raise ClipError("login") from None
        except OSError:
            raise ClipError("unreachable") from None
        refused.unlink(missing_ok=True)
        reader = PacketReader(client.sock, client.session)
        reader.deadline = deadline
        try:
            yield client, reader
        except (OSError, ConnectionError):
            raise ClipError("unreachable") from None
    finally:
        client.close()


def fetch_clip(config_dir: Path, camera_id: str, at: datetime, client_class=None, progress=None,
               ffmpeg: str = "ffmpeg", root: Path | None = None) -> dict:
    root = root or cache_root()
    login, folder = camera_target(config_dir, camera_id, root)
    stem = at.strftime(FILE_TIME_FORMAT)
    out = folder / (stem + ".mp4")                   # complete clips are reused
    unfinished = folder / (stem + ".partial.mp4")    # short or still-recording clips are refetched

    def done(cached, path=out, window=None, complete=True, duration=None):
        try:
            os.utime(path)
        except FileNotFoundError:
            raise ClipError("failed") from None
        result = {"ok": True, "path": str(path), "cached": cached, "partial": not complete}
        if window:
            result.update(start=window[0].strftime(TIME_FORMAT), end=window[1].strftime(TIME_FORMAT))
        if duration is not None:
            result["duration"] = round(duration, 1)
        return result

    with open(folder / ".lock", "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ClipError("busy") from None
        prune_cache(root)
        if playable(out):
            return done(True)
        out.unlink(missing_ok=True)
        deadline = time.monotonic() + DEADLINE_SEC
        with camera_session(login, folder, client_class, deadline) as (client, reader):
            files = query_files(client, reader, at - timedelta(minutes=3), at + timedelta(minutes=3))
            window = plan_window(files, at)
            if not window:
                raise ClipError("no-recording")
            raw, complete = download(client, reader, window[0], window[1], deadline, progress=progress)
        finished = complete and window[1] < datetime.now() - timedelta(seconds=5)
        target = out if finished else unfinished
        duration = write_mp4(parse_xm(raw), target, ffmpeg)
        if finished:
            unfinished.unlink(missing_ok=True)
        return done(False, target, window, complete, duration)


def playable(path: Path) -> bool:
    """A cached clip is reused only if it is still a readable video."""
    if not path.is_file() or path.stat().st_size == 0:
        return False
    try:
        result = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name",
                                 "-of", "csv=p=0", str(path)], capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return True  # can't check; trust the file
    return result.returncode == 0 and result.stdout.strip() != ""


# --- browsing the card: days, a day's recordings, streamed playback ----------------

def storage_span(client, reader: PacketReader) -> tuple[datetime | None, datetime | None]:
    """Oldest and newest recording on the card(s)."""
    client.send(1020, {"Name": "StorageInfo", "SessionID": client.session_id})
    disks = reader.reply(1021).get("StorageInfo")
    oldest, newest = [], []
    for disk in disks if isinstance(disks, list) else []:
        for part in (disk.get("Partition") or []) if isinstance(disk, dict) else []:
            first, last = parse_time(part.get("OldStartTime")), parse_time(part.get("NewEndTime"))
            if first and last and first.year > 2000 and last >= first:
                oldest.append(first)
                newest.append(last)
    return (min(oldest), max(newest)) if oldest else (None, None)


def day_index(files: list, day: date) -> dict:
    """A day's recorded time merged into ranges, plus its motion recordings."""
    day_start = datetime.combine(day, daytime.min)
    day_end = day_start + timedelta(days=1) - timedelta(seconds=1)
    spans, motion = [], []
    for entry in files:
        if not isinstance(entry, dict):
            continue
        begin, end = parse_time(entry.get("BeginTime")), parse_time(entry.get("EndTime"))
        if not begin or not end or end < begin or end < day_start or begin > day_end:
            continue
        begin, end = max(begin, day_start), min(end, day_end)
        spans.append((begin, end))
        if "[M]" in str(entry.get("FileName", "")):
            motion.append((begin, end))
    merged = []
    for begin, end in sorted(spans):
        if merged and begin <= merged[-1][1] + timedelta(seconds=2):
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([begin, end])
    clock = "%H:%M:%S"
    return {"ranges": [[b.strftime(clock), e.strftime(clock)] for b, e in merged],
            "motion": [[b.strftime(clock), e.strftime(clock)] for b, e in sorted(set(motion))]}


def recording_index(config_dir: Path, camera_id: str, day: date | None = None, client_class=None,
                    root: Path | None = None) -> dict:
    login, folder = camera_target(config_dir, camera_id, root or cache_root())
    with camera_session(login, folder, client_class, time.monotonic() + 45) as (client, reader):
        oldest, newest = storage_span(client, reader)
        last = newest.date() if newest else date.today()
        first = max(oldest.date() if oldest else last - timedelta(days=6), last - timedelta(days=MAX_DAYS - 1))
        day = day or last
        files = query_files(client, reader, datetime.combine(day, daytime.min),
                            datetime.combine(day, daytime(23, 59, 59)), pages=40)
    days = [(last - timedelta(days=n)).isoformat() for n in range((last - first).days + 1)]
    return {"ok": True, "days": days, "date": day.isoformat(), **day_index(files, day)}


def plan_playback(files: list, at: datetime) -> datetime | None:
    """Where playback starts: at that moment if it was recorded, else the next recording."""
    later = []
    for entry in files:
        if not isinstance(entry, dict):
            continue
        begin, end = parse_time(entry.get("BeginTime")), parse_time(entry.get("EndTime"))
        if not begin or not end:
            continue
        if begin - timedelta(seconds=2) <= at <= end:
            return max(at, begin)
        if begin > at:
            later.append(begin)
    return min(later) if later else None


def _crc32_mpeg(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return crc


class TsVideoWriter:
    """Wraps camera video frames in MPEG-TS with a timestamp on each frame.

    ffmpeg can't time raw H.264/H.265 from a pipe: its packets carry no
    timestamps, so its scheduler keeps reading video and starves the audio
    input. A few hand-made TS packets fix that: PAT, PMT, one PES per frame.
    """

    PMT_PID, VIDEO_PID = 0x1000, 0x0100
    STREAM_TYPES = {"hevc": 0x24, "h264": 0x1B}

    def __init__(self, codec: str):
        self.stream_type = self.STREAM_TYPES[codec]
        self.counters = {}
        self.frames = 0

    def _packets(self, pid: int, payload: bytes, start: bool, pcr_base: int | None = None) -> bytes:
        """Split a payload into 188-byte TS packets (stuffing the last one)."""
        out, first = bytearray(), True
        while payload or first:
            field = None  # adaptation field contents, after its length byte
            if first and pcr_base is not None:
                base = pcr_base & ((1 << 33) - 1)
                field = b"\x10" + struct.pack(">IH", base >> 1, ((base & 1) << 15) | 0x7E00)
            room = 184 - (1 + len(field) if field is not None else 0)
            chunk, payload = payload[:room], payload[room:]
            short = room - len(chunk)
            if short:
                if field is not None:
                    field += b"\xff" * short
                elif short == 1:
                    field = b""  # just the length byte
                else:
                    field = b"\x00" + b"\xff" * (short - 2)
            counter = self.counters.get(pid, 0)
            self.counters[pid] = (counter + 1) & 0x0F
            header = bytes([0x47, (0x40 if first and start else 0) | (pid >> 8), pid & 0xFF,
                            (0x30 if field is not None else 0x10) | counter])
            packet = header + (bytes([len(field)]) + field if field is not None else b"") + chunk
            assert len(packet) == 188
            out += packet
            first = False
        return bytes(out)

    def _section(self, table_id: int, body: bytes) -> bytes:
        section = bytes([table_id]) + struct.pack(">H", 0xB000 | (len(body) + 4)) + body
        return b"\x00" + section + struct.pack(">I", _crc32_mpeg(section))

    def tables(self) -> bytes:
        pat = self._section(0x00, struct.pack(">HBBBHH", 1, 0xC1, 0, 0, 1, 0xE000 | self.PMT_PID))
        pmt = self._section(0x02, struct.pack(">HBBBHHBHH", 1, 0xC1, 0, 0, 0xE000 | self.VIDEO_PID, 0xF000,
                                              self.stream_type, 0xE000 | self.VIDEO_PID, 0xF000))
        return self._packets(0, pat, True) + self._packets(self.PMT_PID, pmt, True)

    def frame(self, data: bytes, seconds: float) -> bytes:
        ticks = int(round(seconds * 90000)) + 90000  # start at 1 s; 90 kHz clock
        pts = bytes([0x21 | ((ticks >> 29) & 0x0E), (ticks >> 22) & 0xFF, 0x01 | ((ticks >> 14) & 0xFE),
                     (ticks >> 7) & 0xFF, 0x01 | ((ticks << 1) & 0xFE)])
        pes = b"\x00\x00\x01\xe0\x00\x00\x80\x80\x05" + pts + data
        out = self.tables() if self.frames % 48 == 0 else b""
        self.frames += 1
        return out + self._packets(self.VIDEO_PID, pes, True, pcr_base=ticks - 9000)


def _accept_player(server: socket.socket, token: str) -> socket.socket:
    """Wait for the player's GET of our private URL; anything else gets a 404."""
    deadline = time.monotonic() + PLAY_ACCEPT_SEC
    while True:
        server.settimeout(max(0.1, deadline - time.monotonic()))
        try:
            conn, _ = server.accept()
        except TimeoutError:
            raise ClipError("timeout") from None
        conn.settimeout(5)
        try:
            request = conn.recv(4096).decode("latin-1", "replace").split("\r\n", 1)[0].split()
        except OSError:
            conn.close()
            continue
        if len(request) >= 2 and request[0] == "GET" and request[1] == f"/{token}.ts":
            conn.sendall(b"HTTP/1.0 200 OK\r\nContent-Type: video/mp2t\r\nCache-Control: no-store\r\n"
                         b"Connection: close\r\n\r\n")
            conn.settimeout(PLAY_SEND_TIMEOUT_SEC)  # the player's pace is ours: it backs up to the camera
            return conn
        try:
            conn.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        except OSError:
            pass
        conn.close()


class _PipeWriter(threading.Thread):
    """Feeds one ffmpeg input. Its queue never blocks the producer (blocking on
    video while ffmpeg waits for audio would deadlock); `backlog` tells the
    producer when to stop reading the camera instead."""

    def __init__(self, fd: int, stop: threading.Event):
        super().__init__(daemon=True)
        self.fd, self.stop = fd, stop
        self.queue = queue.Queue()
        self.backlog = 0  # bytes queued, not yet written

    def run(self):
        try:
            while True:
                chunk = self.queue.get()
                if chunk is None:
                    break
                view = memoryview(chunk)
                while view:
                    view = view[os.write(self.fd, view):]
                self.backlog -= len(chunk)
        except OSError:
            self.stop.set()
        finally:
            try:
                os.close(self.fd)
            except OSError:
                pass


def _pump_to_player(client, reader: PacketReader, begin: datetime, end: datetime, conn: socket.socket,
                    ffmpeg: str = "ffmpeg", say=None):
    """Camera download → XM frames → ffmpeg (video copied, audio to AAC) → MPEG-TS → player.

    Nothing touches the disk. Backpressure runs the whole way: a paused player
    stops ffmpeg, which stops the queues, which stops reading the camera.
    """
    params = {"PlayMode": "ByTime", "FileName": "", "StreamType": 0, "Value": 0, "TransMode": "TCP", "Channel": 0}

    def body(action):
        return {"Name": "OPPlayBack", "SessionID": client.session_id, "OPPlayBack": {
            "Action": action, "Parameter": params,
            "StartTime": begin.strftime(TIME_FORMAT), "EndTime": end.strftime(TIME_FORMAT)}}

    stop = threading.Event()
    process, writers, sender, claimed = None, {}, None, False
    sent = [0]
    timing = {"ts": None, "fps": 12.0, "index": 0}
    alive_every = max(2.0, getattr(client, "alive_interval", 20) / 2)
    last_alive = time.monotonic()

    def keep_alive():
        nonlocal last_alive
        if time.monotonic() - last_alive > alive_every:
            client.keepalive()
            last_alive = time.monotonic()

    def put(kind, data):
        if kind == "video":  # timestamped by frame number, so ffmpeg reads both inputs in step
            data = timing["ts"].frame(data, timing["index"] / timing["fps"])
            timing["index"] += 1
        writers[kind].backlog += len(data)
        writers[kind].queue.put(data)

    def wait_for_player():
        # A paused or slow player: stop reading the camera until ffmpeg catches up.
        waited = time.monotonic()
        while not stop.is_set() and any(w.backlog > limit for w, limit in (
                (writers.get("video"), 4 * 1024 * 1024), (writers.get("audio"), 256 * 1024)) if w):
            time.sleep(0.2)
            keep_alive()
            if DEBUG and time.monotonic() - waited > 3:
                debug("waiting for the player:", {k: w.backlog // 1024 for k, w in writers.items()})
                waited = time.monotonic()

    def start_ffmpeg(media: XmMedia, with_audio: bool):
        nonlocal process, sender
        video_read, video_write = os.pipe()
        timing["ts"], timing["fps"] = TsVideoWriter(media.codec), float(media.fps or 12)
        if say and media.first_time:  # the stream starts at a key frame, a little before `begin`
            say({"first": media.first_time.strftime(TIME_FORMAT)})
        command = [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error",
                   "-thread_queue_size", "1024", "-analyzeduration", "1000000", "-probesize", "1000000",
                   "-f", "mpegts", "-i", f"pipe:{video_read}"]
        fds = [video_read]
        if with_audio:
            audio_read, audio_write = os.pipe()
            command += ["-thread_queue_size", "1024", "-f", "alaw", "-ar", str(AUDIO_RATE), "-ac", "1",
                        "-i", f"pipe:{audio_read}"]
            fds.append(audio_read)
        command += ["-map", "0:v:0"] + (["-map", "1:a:0"] if with_audio else []) + ["-c:v", "copy"]
        command += (["-c:a", "aac", "-b:a", "48k"] if with_audio else []) + ["-f", "mpegts", "-flush_packets", "1", "pipe:1"]
        debug("ffmpeg start", media.codec, media.fps, "audio" if with_audio else "no audio")
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=None if DEBUG else subprocess.DEVNULL,
                                   pass_fds=fds)
        for fd in fds:
            os.close(fd)
        writers["video"] = _PipeWriter(video_write, stop)
        if with_audio:
            writers["audio"] = _PipeWriter(audio_write, stop)
        for writer in writers.values():
            writer.start()

        def send():
            try:
                while True:
                    chunk = process.stdout.read1(65536)
                    if not chunk:
                        break
                    conn.sendall(chunk)
                    sent[0] += len(chunk)
            except OSError as error:
                debug("send stopped", type(error).__name__)
            finally:
                stop.set()  # player gone or stream finished
        sender = threading.Thread(target=send, daemon=True)
        sender.start()

    try:
        claimed = True
        client.send(PLAYBACK_CLAIM, body("Claim"))
        if reader.reply(PLAYBACK_CLAIM + 1).get("Ret") not in OK_CODES:
            raise ClipError("no-recording")
        client.send(PLAYBACK, body("DownloadStart"))
        assembler, pending, held = XmAssembler(collect=False), bytearray(), []
        began, received = time.monotonic(), 0
        while not stop.is_set():
            keep_alive()
            msg, payload = reader.packet()
            if msg == PLAYBACK + 1 and payload[:1] == b"{":
                if motiond.dvrip_json(payload).get("Ret") not in OK_CODES:
                    raise ClipError("no-recording")
                continue
            if msg != PLAYBACK_DATA:
                debug("other message", msg, len(payload))
                continue
            final = not payload
            pending += payload
            received += len(payload)
            if DEBUG and received // 262144 != (received - len(payload)) // 262144:
                debug(f"received {received // 1024} KB, frames {assembler.media.frames}, sent {sent[0] // 1024} KB,"
                      f" t={time.monotonic() - began:.1f}s, queued "
                      + ", ".join(f"{k} {w.backlog // 1024} KB" for k, w in writers.items())
                      + f", pending {len(pending)}, held {len(held)}")
            frames, used = split_frames(bytes(pending), final=final)
            del pending[:used]
            for frame in frames:
                kind = assembler.add(frame)
                if kind:
                    held.append((kind, frame.payload))
            if process is None and assembler.media.codec and (
                    final or assembler.media.frames >= 24 or any(k == "audio" for k, _ in held)):
                start_ffmpeg(assembler.media, any(k == "audio" for k, _ in held))
            if process is not None:
                for kind, data in held:
                    if kind in writers:
                        put(kind, data)
                held.clear()
                wait_for_player()
            if final:
                break
            ahead = received / PLAY_RATE_LIMIT_BYTES - (time.monotonic() - began)
            if ahead > 0:
                time.sleep(ahead)
    except (OSError, ConnectionError):
        pass  # the camera stopped sending: end of stream
    finally:
        if claimed:
            try:
                client.sock.settimeout(5)
                client.send(PLAYBACK, body("DownloadStop"))
            except OSError:
                pass
        for writer in writers.values():
            writer.queue.put(None)  # EOF lets ffmpeg flush the tail
        if sender is not None:
            sender.join(timeout=0 if stop.is_set() else 15)
        if process is not None:
            if process.poll() is None:
                process.kill()
            process.wait()
        try:
            conn.close()
        except OSError:
            pass


def stream_playback(config_dir: Path, camera_id: str, at: datetime, say, client_class=None,
                    root: Path | None = None, ffmpeg: str = "ffmpeg") -> dict:
    """Play the card from `at` (or the next recording) through a private local URL."""
    login, folder = camera_target(config_dir, camera_id, root or cache_root())
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        server.bind(("127.0.0.1", 0))
        server.listen(2)
        token = secrets.token_urlsafe(18)
        with camera_session(login, folder, client_class, time.monotonic() + 30) as (client, reader):
            files = query_files(client, reader, at - timedelta(minutes=3), at + timedelta(hours=6), pages=4)
            begin = plan_playback(files, at)
            if not begin:
                raise ClipError("no-recording")
            end = min(begin + timedelta(seconds=PLAY_SPAN_SEC), datetime.combine(begin.date(), daytime(23, 59, 59)))
            say({"url": f"http://127.0.0.1:{server.getsockname()[1]}/{token}.ts",
                 "start": begin.strftime(TIME_FORMAT), "end": end.strftime(TIME_FORMAT)})
            conn = _accept_player(server, token)
            reader.deadline = None
            client.sock.settimeout(PACKET_TIMEOUT_SEC)
            _pump_to_player(client, reader, begin, end, conn, ffmpeg, say)
        return {"ended": True, "start": begin.strftime(TIME_FORMAT), "end": end.strftime(TIME_FORMAT)}
    finally:
        server.close()


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
    try:
        print(json.dumps(data), flush=True)
    except BrokenPipeError:
        pass


def _cancel(signum, frame):  # noqa: ARG001
    # Unwind normally so the camera is told to stop sending (see download()).
    raise ClipError("cancelled")


def main(argv=None) -> int:
    os.umask(0o077)
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, _cancel)
    parser = argparse.ArgumentParser(description="Fetch a clip from a camera's SD card.")
    parser.add_argument("--camera", required=True)
    parser.add_argument("--at")
    parser.add_argument("--save")
    parser.add_argument("--index", action="store_true", help="days on the card and one day's recordings")
    parser.add_argument("--date", help="YYYY-MM-DD for --index (default: newest day)")
    parser.add_argument("--play", action="store_true", help="stream the card from --at to a local URL")
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
        if args.index:
            day = None
            if args.date:
                if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.date):
                    raise ClipError("bad-request")
                try:
                    day = date.fromisoformat(args.date)
                except ValueError:
                    raise ClipError("bad-request") from None
            emit(recording_index(config_dir, args.camera, day))
            return 0
        if not args.at or not re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", args.at):
            raise ClipError("bad-request")
        at = parse_time(args.at)
        if not at:
            raise ClipError("bad-request")
        if args.play:
            emit(stream_playback(config_dir, args.camera, at, emit))
            return 0

        def progress(size):
            try:
                print(json.dumps({"progress": size}), flush=True)
            except BrokenPipeError:
                raise ClipError("cancelled") from None  # nobody is listening any more
        emit(fetch_clip(config_dir, args.camera, at, progress=progress))
        return 0
    except ClipError as error:
        emit({"ok": False, "error": error.code})
    except Exception as error:  # noqa: BLE001 - never print messages that could carry credentials
        emit({"ok": False, "error": "failed", "detail": type(error).__name__})
    return 1


if __name__ == "__main__":
    sys.exit(main())
