#!/usr/bin/env python3
"""Always-on motion still capture for yani.camera, for every saved camera.

One worker thread per camera: ONVIF PullPoint events (with HTTP snapshots)
for cameras reachable directly, or DVRIP alarms (with DVRIP snapshots) for
XMeye/iCSee cameras behind the local go2rtc bridge. Stills go to
<motion dir>/<camera id>/. Stdlib only; never logs credentials.
CLI:
  (default)            run capture loops until SIGTERM
  --list               print JSON array of saved stills (newest first)
  --status             print listener status as JSON
  --once [--camera ID] capture one still now (debug)
  --prune-only         apply retention then exit
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import html
import json
import os
import re
import signal
import socket
import ssl
import struct
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

HTTP_TIMEOUT = 8
PULL_TIMEOUT_SEC = 30
RENEW_MARGIN_SEC = 15
DEFAULT_RETENTION_HOURS = 24
DEFAULT_MAX_FILES = 400
DEFAULT_MIN_INTERVAL_SEC = 5
SNAPSHOT_RETRY = 2
PRUNE_EVERY_SEC = 300
IDLE_POLL_SEC = 15
# Some firmwares ignore the PullMessages Timeout and answer instantly; pace the loop.
MIN_PULL_PERIOD_SEC = 1.0
CONFIG_CHECK_SEC = 10

_STOP = False


def _handle_signal(signum, frame):  # noqa: ARG001
    global _STOP
    _STOP = True


def base_dirs():
    xdg = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    data = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    config_dir = Path(xdg) / "rtsp-camera"
    motion_dir = Path(data) / "rtsp-camera" / "motion"
    return config_dir, motion_dir


def load_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return default


def _write_private_json(path: Path, data) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def ensure_motion_config(config_dir: Path, library) -> dict:
    """Load motion.json, creating or migrating it.

    `cameraIds` is "all" (every saved camera, including ones added later) or a
    list of ids. The old single `cameraId` migrates to "all", and that camera
    becomes `legacyCameraId`: the owner of stills saved before per-camera
    folders existed.
    """
    path = config_dir / "motion.json"
    data = load_json(path, None)
    changed = False
    if not isinstance(data, dict):
        data = {}
        changed = True
    if "cameraIds" not in data:
        old = data.pop("cameraId", "")
        if old and not data.get("legacyCameraId"):
            data["legacyCameraId"] = old
        data["cameraIds"] = "all"
        changed = True
    elif "cameraId" in data:
        data.pop("cameraId")
        changed = True
    for key, value in (("enabled", True), ("retentionHours", DEFAULT_RETENTION_HOURS),
                       ("maxFiles", DEFAULT_MAX_FILES), ("minIntervalSec", DEFAULT_MIN_INTERVAL_SEC)):
        if key not in data:
            data[key] = value
            changed = True
    if changed:
        _write_private_json(path, data)
    return data


def monitored_cameras(library, motion_cfg) -> list[dict]:
    """Saved cameras that motion capture should watch, in library order."""
    cameras = [c for c in (library.get("cameras") or []) if isinstance(c, dict) and valid_camera_id(c.get("id"))]
    wanted = motion_cfg.get("cameraIds", "all")
    if wanted == "all":
        return cameras
    if not isinstance(wanted, list):
        return []
    return [c for c in cameras if c.get("id") in wanted]


_CAMERA_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def valid_camera_id(camera_id) -> bool:
    """Camera ids become folder names; reject anything that could escape the motion dir."""
    return isinstance(camera_id, str) and bool(_CAMERA_ID_RE.match(camera_id))


def find_camera(library, camera_id: str):
    for camera in library.get("cameras") or []:
        if camera.get("id") == camera_id:
            return camera
    return None


def extract_path_credentials(url: str) -> tuple[str, str]:
    """Parse XM-style user=NAME_password=PASS_ fragments in the RTSP path."""
    split = urlsplit(url)
    path = f"{split.path}?{split.query or ''}"
    match = re.search(r"user=([^_]+)_password=([^_]+)_", path)
    if not match:
        return "", ""
    return match.group(1), match.group(2)


def credentials_for(camera: dict) -> tuple[str, str]:
    user = camera.get("username") or ""
    password = camera.get("password") or ""
    if user or password:
        return user, password
    return extract_path_credentials(camera.get("url") or "")


def ensure_dirs(motion_dir: Path):
    motion_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        os.chmod(motion_dir, 0o700)
    except OSError:
        pass


def still_filename(when: datetime | None = None) -> str:
    stamp = (when or datetime.now()).astimezone().strftime("%Y-%m-%d_%H-%M-%S")
    return f"{stamp}.jpg"


def parse_still_time(name: str) -> datetime | None:
    match = re.match(r"(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})\.jpe?g$", name, re.I)
    if not match:
        return None
    try:
        return datetime.strptime(
            f"{match.group(1)} {match.group(2)}:{match.group(3)}:{match.group(4)}",
            "%Y-%m-%d %H:%M:%S",
        ).astimezone()
    except ValueError:
        return None


def camera_dir(motion_dir: Path, camera_id: str) -> Path:
    if not valid_camera_id(camera_id):
        raise ValueError("invalid camera id")
    return motion_dir / camera_id


def _still_entries(directory: Path):
    if not directory.is_dir():
        return
    for path in directory.iterdir():
        if path.is_file() and path.suffix.lower() in (".jpg", ".jpeg"):
            yield path


def list_stills(motion_dir: Path, names: dict | None = None, legacy_camera_id: str = "") -> list[dict]:
    """Stills from every camera folder, newest first.

    Files directly in motion_dir predate per-camera folders and belong to
    legacy_camera_id. `names` maps camera ids to display names.
    """
    if not motion_dir.is_dir():
        return []
    names = names or {}
    sources = [(legacy_camera_id, motion_dir)]
    for child in motion_dir.iterdir():
        if child.is_dir() and valid_camera_id(child.name):
            sources.append((child.name, child))
    items = []
    for camera_id, directory in sources:
        for path in _still_entries(directory):
            when = parse_still_time(path.name)
            try:
                mtime = path.stat().st_mtime
            except OSError:
                continue
            items.append(
                {
                    "name": path.name,
                    "path": str(path),
                    "mtime": mtime,
                    "time": when.strftime("%H:%M:%S") if when else "",
                    "date": when.strftime("%Y-%m-%d") if when else "",
                    "cameraId": camera_id,
                    "cameraName": names.get(camera_id, ""),
                }
            )
    items.sort(key=lambda item: item["mtime"], reverse=True)
    return items


def prune_stills(
    motion_dir: Path,
    retention_hours: int = DEFAULT_RETENTION_HOURS,
    max_files: int = DEFAULT_MAX_FILES,
    now: float | None = None,
) -> int:
    """Delete stills older than retention_hours and beyond max_files. Returns removed count."""
    if not motion_dir.is_dir():
        return 0
    now = time.time() if now is None else now
    cutoff = now - max(1, int(retention_hours)) * 3600
    files = []
    removed = 0
    for path in motion_dir.iterdir():
        if not path.is_file() or path.suffix.lower() not in (".jpg", ".jpeg"):
            continue
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        files.append((mtime, path))
    files.sort(key=lambda pair: pair[0], reverse=True)
    keep_limit = max(0, int(max_files))
    for index, (mtime, path) in enumerate(files):
        drop = mtime < cutoff or index >= keep_limit
        if not drop:
            continue
        try:
            path.unlink()
            removed += 1
        except OSError:
            pass
    return removed


def prune_all(motion_dir: Path, retention_hours: int, max_files: int, now: float | None = None) -> int:
    """Apply retention to the legacy folder and to each camera folder (max_files per camera)."""
    if not motion_dir.is_dir():
        return 0
    removed = prune_stills(motion_dir, retention_hours, max_files, now=now)
    for child in motion_dir.iterdir():
        if child.is_dir() and valid_camera_id(child.name):
            removed += prune_stills(child, retention_hours, max_files, now=now)
    return removed


class StatusBoard:
    """Thread-safe writer for .status.json.

    Layout: {"enabled", "updated", "cameras": {id: {name, source, listening,
    lastError, lastEvent, lastReason, count}}} plus a summary ("listening",
    "camera", "lastError") for older readers. Errors are exception class
    names only: bridge URLs carry credentials.
    """

    def __init__(self, motion_dir: Path):
        self.path = motion_dir / ".status.json"
        self.motion_dir = motion_dir
        self.lock = threading.Lock()

    def _write(self, mutate):
        with self.lock:
            ensure_dirs(self.motion_dir)
            current = load_json(self.path, {})
            if not isinstance(current, dict):
                current = {}
            if not isinstance(current.get("cameras"), dict):
                current = {"cameras": {}}
            mutate(current)
            cameras = current["cameras"].values()
            current["listening"] = any(c.get("listening") for c in cameras)
            current["camera"] = ", ".join(c.get("name", "") for c in cameras if c.get("name"))
            current["lastError"] = next((c["lastError"] for c in cameras if c.get("lastError")), "")
            current["updated"] = datetime.now(timezone.utc).isoformat()
            tmp = self.path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(current) + "\n")
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.path)

    def update(self, camera_id: str, **fields):
        def mutate(current):
            current["cameras"].setdefault(camera_id, {}).update(fields)
        self._write(mutate)

    def set_global(self, **fields):
        self._write(lambda current: current.update(fields))

    def keep_only(self, camera_ids):
        def mutate(current):
            current["cameras"] = {k: v for k, v in current["cameras"].items() if k in camera_ids}
        self._write(mutate)


_HTTP_LOCAL = threading.local()


def _opener() -> urllib.request.OpenerDirector:
    """One opener per thread, built once.

    Building an opener (and an SSL context) for every request made glibc
    fragment the heap: with a camera that answers PullMessages instantly the
    loop runs about once a second and RSS grew ~9 MB a minute. The HTTPS
    context is created here too, once per thread, for https snapshot URLs.
    """
    opener = getattr(_HTTP_LOCAL, "opener", None)
    if opener is None:
        opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=ssl.create_default_context()))
        _HTTP_LOCAL.opener = opener
    return opener


def _http(method: str, url: str, data: bytes | None = None, headers: dict | None = None) -> bytes:
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    with _opener().open(req, timeout=HTTP_TIMEOUT) as resp:
        return resp.read()


def onvif_soap(endpoint: str, body: str, action: str | None = None) -> str:
    envelope = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"'
        ' xmlns:wsa="http://www.w3.org/2005/08/addressing"'
        ' xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2"'
        ' xmlns:tev="http://www.onvif.org/ver10/events/wsdl"'
        ' xmlns:tt="http://www.onvif.org/ver10/schema">'
        f"<s:Header>{'<' + 'wsa:Action>' + html.escape(action) + '</wsa:Action>' if action else ''}"
        f"<wsa:MessageID>urn:uuid:{uuid.uuid4()}</wsa:MessageID>"
        "</s:Header>"
        f"<s:Body>{body}</s:Body>"
        "</s:Envelope>"
    ).encode()
    headers = {
        "Content-Type": "application/soap+xml; charset=utf-8",
    }
    if action:
        headers["SOAPAction"] = f'"{action}"'
    return _http("POST", endpoint, data=envelope, headers=headers).decode("utf-8", "replace")


def xml_find(text: str, local: str) -> str | None:
    patterns = (
        rf"<{local}[^>]*>(.*?)</{local}>",
        rf"<[^:>]+:{local}[^>]*>(.*?)</[^:>]+:{local}>",
    )
    for pattern in patterns:
        match = re.search(pattern, text, re.S | re.I)
        if match:
            inner = match.group(1).strip()
            if inner.startswith("<"):
                continue
            return html.unescape(inner)
    return None


def resolve_event_xaddr(host: str) -> str:
    device = f"http://{host}:8899/onvif/device_service"
    body = (
        "<tds:GetServices xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\">"
        "<tds:IncludeCapability>false</tds:IncludeCapability></tds:GetServices>"
    )
    try:
        reply = onvif_soap(device, body)
        # Prefer events namespace XAddr
        chunks = re.findall(
            r"<tds:Service>(.*?)</tds:Service>",
            reply,
            re.S | re.I,
        )
        for chunk in chunks:
            ns = xml_find(chunk, "Namespace") or ""
            xaddr = xml_find(chunk, "XAddr") or ""
            if "events" in ns.lower() and xaddr:
                return xaddr
    except (urllib.error.URLError, OSError, socket.timeout):
        pass
    return f"http://{host}:8899/onvif/event_service"


def create_pull_subscription(event_xaddr: str) -> tuple[str, float]:
    # Subscribe to a broad topic set; filter later.
    body = (
        "<tev:CreatePullPointSubscription>"
        "<tev:InitialTerminationTime>PT2M</tev:InitialTerminationTime>"
        "</tev:CreatePullPointSubscription>"
    )
    reply = onvif_soap(event_xaddr, body)
    address = None
    match = re.search(
        r"<[^:>]*:Address[^>]*>(.*?)</[^:>]*:Address>",
        reply,
        re.S | re.I,
    )
    if match:
        address = html.unescape(match.group(1).strip())
    if not address:
        address = xml_find(reply, "Address")
    if not address:
        raise RuntimeError("ONVIF subscription address missing")
    # Some firmwares return relative addresses
    if address.startswith("/"):
        parts = urllib.parse.urlsplit(event_xaddr)
        address = f"{parts.scheme}://{parts.netloc}{address}"
    return address, time.time() + 120


def pull_messages(sub_addr: str, timeout_sec: int = PULL_TIMEOUT_SEC) -> str:
    body = (
        f"<tev:PullMessages>"
        f"<tev:MessageLimit>10</tev:MessageLimit>"
        f"<tev:Timeout>PT{timeout_sec}S</tev:Timeout>"
        f"</tev:PullMessages>"
    )
    return onvif_soap(sub_addr, body)


def renew_subscription(sub_addr: str, expires_sec: int = 120) -> None:
    body = (
        "<wsnt:Renew>"
        f"<wsnt:TerminationTime>PT{expires_sec}S</wsnt:TerminationTime>"
        "</wsnt:Renew>"
    )
    onvif_soap(sub_addr, body)


def unsubscribe(sub_addr: str) -> None:
    try:
        onvif_soap(sub_addr, "<wsnt:Unsubscribe/>")
    except (urllib.error.URLError, OSError, socket.timeout, RuntimeError):
        pass


_NOTIFICATION_RE = re.compile(
    r"<(?:[^:>]+:)?NotificationMessage\b.*?</(?:[^:>]+:)?NotificationMessage>", re.S | re.I
)
_TOPIC_RE = re.compile(r"<(?:[^:>]+:)?Topic\b[^>]*>(.*?)</(?:[^:>]+:)?Topic>", re.S | re.I)
_DATA_RE = re.compile(r"<(?:[^:>]+:)?Data\b[^>]*>(.*?)</(?:[^:>]+:)?Data>", re.S | re.I)
_ITEM_RE = re.compile(
    r"<(?:[^:>]+:)?SimpleItem\b[^>]*\bName=\"(IsMotion|State|Motion)\"[^>]*\bValue=\"([^\"]*)\"",
    re.I,
)


def event_looks_like_motion(reply: str) -> bool:
    """True only when a motion-topic notification carries an active (true) state."""
    for note in _NOTIFICATION_RE.findall(reply):
        topic = _TOPIC_RE.search(note)
        if not topic or "motion" not in topic.group(1).lower():
            continue
        data = _DATA_RE.search(note)
        if not data:
            continue
        for _, value in _ITEM_RE.findall(data.group(1)):
            if value.strip().lower() in ("true", "1"):
                return True
    return False


def get_snapshot_url(host: str, user: str, password: str) -> str:
    device_media = f"http://{host}:8899/onvif/media_service"
    body = (
        "<trt:GetSnapshotUri xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\">"
        "<trt:ProfileToken>000</trt:ProfileToken>"
        "</trt:GetSnapshotUri>"
    )
    try:
        reply = onvif_soap(device_media, body)
        uri = xml_find(reply, "Uri")
        if uri and uri.startswith("http"):
            return uri
    except (urllib.error.URLError, OSError, socket.timeout, RuntimeError):
        pass
    # Fallback: classic XM webcapture (no creds in query if we pass basic-style params)
    query = urllib.parse.urlencode(
        {"command": "snap", "channel": 0, "user": user, "password": password}
    )
    return f"http://{host}/webcapture.jpg?{query}"


def fetch_snapshot(url: str) -> bytes:
    last_error = None
    for _ in range(SNAPSHOT_RETRY):
        try:
            data = _http("GET", url)
            if data[:2] == b"\xff\xd8" or data[:4] == b"\x89PNG":
                return data
            # Some builds return JSON error
            last_error = RuntimeError("snapshot not an image")
        except (urllib.error.URLError, OSError, socket.timeout) as error:
            last_error = error
        time.sleep(0.2)
    raise last_error or RuntimeError("snapshot failed")


def save_still(motion_dir: Path, data: bytes) -> Path:
    ensure_dirs(motion_dir)
    name = still_filename()
    path = motion_dir / name
    # Avoid overwrite within the same second
    if path.exists():
        path = motion_dir / f"{name[:-4]}_{uuid.uuid4().hex[:4]}.jpg"
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    return path


LOOPBACK_HOSTS = {"127.0.0.1", "::1", "localhost"}
BRIDGE_CONFIG = "go2rtc.private.json"


def resolve_bridge_source(config_dir: Path, url: str) -> str | None:
    """Follow a local go2rtc stream (rtsp://127.0.0.1:8554/<name>) to its upstream URL.

    Handles references between streams and ffmpeg: transcoding wrappers, e.g.
    icsee_plugin -> "ffmpeg:icsee_baja#video=h264" -> "dvrip://user:pass@host".
    """
    split = urlsplit(url)
    if (split.hostname or "") not in LOOPBACK_HOSTS:
        return None
    bridge = load_json(config_dir / BRIDGE_CONFIG, None)
    streams = bridge.get("streams") if isinstance(bridge, dict) else None
    if not isinstance(streams, dict):
        return None
    name = split.path.lstrip("/").split("/", 1)[0]
    seen = set()
    while name in streams and name not in seen:
        seen.add(name)
        source = streams[name]
        if isinstance(source, list):
            source = source[0] if source else None
        if not isinstance(source, str):
            return None
        if source.startswith("ffmpeg:"):
            source = source[len("ffmpeg:"):]
        source = source.split("#", 1)[0].strip()
        if "://" in source:
            return source
        name = source
    return None


def motion_source(config_dir: Path, camera: dict) -> dict:
    """How to watch a camera for motion: ONVIF events, DVRIP alarms, or nothing."""
    url = camera.get("url") or ""
    upstream = resolve_bridge_source(config_dir, url)
    if upstream:
        split = urlsplit(upstream)
        if split.scheme == "dvrip" and split.hostname:
            return {"kind": "dvrip", "host": split.hostname, "port": split.port or DVRIP_PORT,
                    "user": urllib.parse.unquote(split.username or ""),
                    "password": urllib.parse.unquote(split.password or "")}
        if split.scheme in ("rtsp", "rtsps") and split.hostname and split.hostname not in LOOPBACK_HOSTS:
            user = urllib.parse.unquote(split.username or "")
            password = urllib.parse.unquote(split.password or "")
            if not (user or password):
                user, password = extract_path_credentials(upstream)
            return {"kind": "onvif", "host": split.hostname, "user": user, "password": password}
        return {"kind": "none", "reason": "Unsupported bridge source."}
    host = urlsplit(url).hostname or ""
    if not host or host in LOOPBACK_HOSTS:
        return {"kind": "none", "reason": "No motion source for this local stream."}
    user, password = credentials_for(camera)
    return {"kind": "onvif", "host": host, "user": user, "password": password}


# --- DVRIP (XMeye / iCSee "Sofia" protocol) -----------------------------------
DVRIP_PORT = 34567
DVRIP_LOGIN = 1000
DVRIP_KEEPALIVE = 1006
DVRIP_GUARD = 1500
DVRIP_ALARM = 1504
DVRIP_SNAPSHOT = 1560
DVRIP_SNAPSHOT_REPLY = 1561
DVRIP_MAX_PACKET = 8 * 1024 * 1024
_DVRIP_HEADER = struct.Struct("<BB2xII2xHI")


def sofia_hash(password: str) -> str:
    """XMeye password hash: 8 chars from pairs of MD5 bytes."""
    digest = hashlib.md5(password.encode("utf-8")).digest()
    alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    return "".join(alphabet[(digest[2 * i] + digest[2 * i + 1]) % 62] for i in range(8))


def dvrip_json(data: bytes) -> dict:
    try:
        value = json.loads(data.rstrip(b"\x00\x0a").decode("utf-8", "replace") or "{}")
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def alarm_is_motion_start(message: dict) -> bool:
    info = message.get("AlarmInfo")
    if not isinstance(info, dict):
        return False
    event = str(info.get("Event", "")).lower()
    status = str(info.get("Status", "")).lower()
    return status == "start" and any(word in event for word in ("motion", "human", "pir"))


# Login result codes reported by XMeye firmware.
DVRIP_LOGIN_CODES = {
    106: "wrong user name or password",
    203: "wrong password",
    205: "account locked after too many attempts",
    206: "account blocked",
    207: "account already logged in elsewhere",
}


class DvripLoginError(PermissionError):
    def __init__(self, code):
        self.code = code
        self.reason = DVRIP_LOGIN_CODES.get(code, "login refused")
        super().__init__(f"DVRIP login refused ({code}: {self.reason})")


class DvripClient:
    """Minimal DVRIP session: login, alarm guard, keepalive and JPEG snapshot."""

    def __init__(self, host: str, port: int, user: str, password: str, timeout: float = HTTP_TIMEOUT):
        self.host, self.port = host, port
        self.user, self.password = user, password
        self.timeout = timeout
        self.sock = None
        self.session = 0
        self.sequence = 0
        self.alive_interval = 20
        self.pending_alarms = []

    @property
    def session_id(self) -> str:
        return "0x%08X" % self.session

    def connect(self):
        self.sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        self.send(DVRIP_LOGIN, {"EncryptType": "MD5", "LoginType": "DVRIP-Web",
                                "PassWord": sofia_hash(self.password), "UserName": self.user})
        _, reply = self.recv_reply(DVRIP_LOGIN + 1)
        if reply.get("Ret") not in (100, 515):
            raise DvripLoginError(reply.get("Ret"))
        self.session = int(str(reply.get("SessionID", "0")), 16)
        try:
            self.alive_interval = max(5, int(reply.get("AliveInterval") or 20))
        except (TypeError, ValueError):
            self.alive_interval = 20

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None

    def send(self, msg: int, body: dict):
        data = json.dumps(body).encode("utf-8")
        packet = _DVRIP_HEADER.pack(255, 0, self.session, self.sequence, msg, len(data) + 2) + data + b"\x0a\x00"
        self.sequence += 1
        self.sock.sendall(packet)

    def _recv_exact(self, size: int) -> bytes:
        chunks, remaining = [], size
        while remaining:
            chunk = self.sock.recv(min(remaining, 65536))
            if not chunk:
                raise ConnectionError("DVRIP connection closed")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def recv(self) -> tuple[int, bytes]:
        head, _, _, _, msg, length = _DVRIP_HEADER.unpack(self._recv_exact(_DVRIP_HEADER.size))
        if head != 255 or length > DVRIP_MAX_PACKET:
            raise ConnectionError("bad DVRIP packet")
        return msg, self._recv_exact(length)

    def recv_reply(self, msg_id: int, limit: int = 32) -> tuple[int, dict]:
        """Wait for a reply, setting aside alarms that arrive first."""
        for _ in range(limit):
            msg, data = self.recv()
            if msg == DVRIP_ALARM:
                self.pending_alarms.append(dvrip_json(data))
                continue
            if msg == msg_id:
                return msg, dvrip_json(data)
        raise ConnectionError("DVRIP reply missing")

    def guard(self):
        self.send(DVRIP_GUARD, {"Name": "", "SessionID": self.session_id})
        _, reply = self.recv_reply(DVRIP_GUARD + 1)
        if reply.get("Ret") not in (100, None):
            raise RuntimeError("DVRIP alarm subscription refused")

    def keepalive(self):
        self.send(DVRIP_KEEPALIVE, {"Name": "KeepAlive", "SessionID": self.session_id})

    def snapshot(self, channel: int = 0) -> bytes:
        self.send(DVRIP_SNAPSHOT, {"Name": "OPSNAP", "SessionID": self.session_id,
                                   "OPSNAP": {"Channel": channel}})
        image = b""
        for _ in range(64):
            msg, data = self.recv()
            if msg == DVRIP_ALARM:
                self.pending_alarms.append(dvrip_json(data))
                continue
            if msg != DVRIP_SNAPSHOT_REPLY:
                continue
            image += data
            # Large images arrive in several packets; the JPEG ends with FFD9.
            if image[:2] == b"\xff\xd8" and image.rstrip(b"\x00").endswith(b"\xff\xd9"):
                return image.rstrip(b"\x00")
            if image[:1] == b"{":
                raise RuntimeError("DVRIP snapshot refused")
        raise RuntimeError("DVRIP snapshot incomplete")


# Device ("app") accounts for cameras whose DVRIP login differs from their stream URL.
LOGINS_FILE = "dvrip-logins.json"


def find_camera_ref(library, ref: str):
    """A saved camera by id or by name (case-insensitive)."""
    cameras = [c for c in (library.get("cameras") or []) if isinstance(c, dict)]
    for camera in cameras:
        if camera.get("id") == ref:
            return camera
    for camera in cameras:
        if str(camera.get("name", "")).strip().lower() == ref.strip().lower():
            return camera
    return None


def device_host(config_dir: Path, camera: dict) -> str:
    """The camera's own address, following a local relay (rtsp://127.0.0.1:8554/<name>)."""
    url = camera.get("url") or ""
    upstream = resolve_bridge_source(config_dir, url)
    host = urlsplit(upstream or url).hostname or ""
    return "" if host in LOOPBACK_HOSTS else host


def dvrip_login_for(config_dir: Path, camera: dict) -> dict | None:
    """DVRIP host and account for a camera: its bridge source, or a saved device login."""
    source = motion_source(config_dir, camera)
    if source["kind"] == "dvrip":
        return {key: source[key] for key in ("host", "port", "user", "password")}
    host = device_host(config_dir, camera)
    logins = load_json(config_dir / LOGINS_FILE, {})
    saved = logins.get(camera.get("id")) if isinstance(logins, dict) else None
    if not isinstance(saved, dict) or not host or host in LOOPBACK_HOSTS:
        return None
    return {"host": host, "port": int(saved.get("port") or DVRIP_PORT),
            "user": str(saved.get("user") or ""), "password": str(saved.get("password") or "")}


def cmd_set_login(config_dir: Path, ref: str, ask=input, ask_secret=getpass.getpass, client_class=None,
                  copy_from: str = "") -> int:
    """Try a camera's device login once and save it (0600) only if it works.

    The login is prompted for (password hidden), or copied from another camera
    with copy_from, so a shared app password works without knowing or typing it.
    """
    client_class = client_class or DvripClient
    library = load_json(config_dir / "config.json", {"cameras": []})
    if not isinstance(library, dict):
        library = {"cameras": []}
    camera = find_camera_ref(library, ref)
    if not camera:
        names = ", ".join(str(c.get("name")) for c in library.get("cameras") or [] if isinstance(c, dict))
        print(f"No saved camera called {ref!r}. Cameras: {names}")
        return 2
    if motion_source(config_dir, camera)["kind"] == "dvrip":
        print(f"{camera.get('name')} already uses the login from the local bridge; nothing to do.")
        return 0
    host = device_host(config_dir, camera)
    if not host:
        print(f"{camera.get('name')} has no reachable host in its URL.")
        return 2
    print(f"Device login for {camera.get('name')} ({host}:{DVRIP_PORT}), the account used in the phone app.")
    print("It is tried once; failed tries count toward the camera's lockout.")
    if copy_from:
        donor = find_camera_ref(library, copy_from)
        login = dvrip_login_for(config_dir, donor) if donor else None
        if not login:
            print(f"No device login known for {copy_from!r}. Nothing tried.")
            return 2
        user, password = login["user"], login["password"]
        print(f"Trying the login of {donor.get('name')} (user {user}).")
    else:
        user = ask("User [admin]: ").strip() or "admin"
        password = ask_secret("Password (hidden): ")
    client = client_class(host, DVRIP_PORT, user, password)
    try:
        client.connect()
    except DvripLoginError as error:
        print(f"Login refused: {error.reason} (code {error.code}). Nothing saved.")
        return 1
    except OSError as error:
        print(f"Could not reach {host}:{DVRIP_PORT} ({error.__class__.__name__}). Nothing saved.")
        return 1
    finally:
        client.close()
    path = config_dir / LOGINS_FILE
    logins = load_json(path, {})
    if not isinstance(logins, dict):
        logins = {}
    logins[camera["id"]] = {"user": user, "password": password}
    _write_private_json(path, logins)
    print(f"Login OK. Saved for {camera.get('name')} in {path} (readable only by you).")
    return 0


def retention_settings(cfg: dict) -> tuple[int, int, int]:
    def number(key, default):
        try:
            return int(cfg.get(key) or default)
        except (TypeError, ValueError):
            return default
    return (number("retentionHours", DEFAULT_RETENTION_HOURS), number("maxFiles", DEFAULT_MAX_FILES),
            max(1, number("minIntervalSec", DEFAULT_MIN_INTERVAL_SEC)))


class CameraWorker(threading.Thread):
    """Watches one camera; saves a still into its folder when it reports motion."""

    def __init__(self, camera: dict, source: dict, motion_dir: Path, board: StatusBoard, settings: dict):
        super().__init__(daemon=True, name=f"motion-{camera['id'][:8]}")
        self.camera_id = camera["id"]
        self.camera_name = camera.get("name") or ""
        self.source = source
        self.folder = camera_dir(motion_dir, self.camera_id)
        self.board = board
        self.settings = settings
        self.stop_event = threading.Event()
        self.last_save = 0.0
        self.capture_lock = threading.Lock()

    def stopped(self) -> bool:
        return self.stop_event.is_set() or _STOP

    def status(self, **fields):
        self.board.update(self.camera_id, name=self.camera_name, source=self.source["kind"], **fields)

    def save(self, data: bytes, reason: str) -> Path | None:
        hours, max_files, _ = retention_settings(self.settings)
        path = save_still(self.folder, data)
        self.last_save = time.time()
        prune_stills(self.folder, hours, max_files)
        self.status(lastEvent=datetime.now().astimezone().isoformat(), lastError="", lastReason=reason,
                    count=sum(1 for _ in _still_entries(self.folder)))
        return path

    def due(self) -> bool:
        _, _, min_interval = retention_settings(self.settings)
        return time.time() - self.last_save >= min_interval

    def wait(self, seconds: float):
        self.stop_event.wait(seconds)

    def run(self):
        backoff = 2
        while not self.stopped():
            try:
                self.watch()
                backoff = 2
            except Exception as error:  # noqa: BLE001 — class name only, never URLs or secrets
                self.status(listening=False, lastError=error.__class__.__name__)
                self.wait(backoff)
                backoff = min(60, backoff * 2)
        self.status(listening=False)

    def watch(self):
        raise NotImplementedError

    def capture_now(self, reason: str = "manual") -> Path | None:
        raise NotImplementedError


class OnvifWorker(CameraWorker):
    def snapshot(self) -> bytes:
        source = self.source
        return fetch_snapshot(get_snapshot_url(source["host"], source["user"], source["password"]))

    def capture_now(self, reason: str = "manual") -> Path | None:
        return self.save(self.snapshot(), reason)

    def watch(self):
        sub_addr = None
        expires = 0.0
        try:
            while not self.stopped():
                now = time.time()
                if sub_addr is None or now >= expires - RENEW_MARGIN_SEC:
                    if sub_addr:
                        unsubscribe(sub_addr)
                        sub_addr = None
                    sub_addr, expires = create_pull_subscription(resolve_event_xaddr(self.source["host"]))
                    self.status(listening=True, lastError="")
                started = time.time()
                reply = pull_messages(sub_addr, timeout_sec=PULL_TIMEOUT_SEC)
                expires = time.time() + 110
                if event_looks_like_motion(reply) and self.due():
                    try:
                        self.capture_now("onvif")
                    except Exception as error:  # noqa: BLE001 — keep listening; report the class only
                        self.status(lastError=error.__class__.__name__)
                elapsed = time.time() - started
                if elapsed < MIN_PULL_PERIOD_SEC:
                    self.wait(MIN_PULL_PERIOD_SEC - elapsed)
        finally:
            if sub_addr:
                unsubscribe(sub_addr)


class DvripWorker(CameraWorker):
    def client(self) -> DvripClient:
        source = self.source
        return DvripClient(source["host"], source["port"], source["user"], source["password"])

    def capture_now(self, reason: str = "manual") -> Path | None:
        client = self.client()
        try:
            client.connect()
            return self.save(client.snapshot(), reason)
        finally:
            client.close()

    def watch(self):
        client = self.client()
        try:
            client.connect()
            client.guard()
            client.sock.settimeout(1.0)
            self.status(listening=True, lastError="")
            last_keepalive = time.time()
            while not self.stopped():
                if time.time() - last_keepalive >= client.alive_interval / 2:
                    client.keepalive()
                    last_keepalive = time.time()
                alarms, client.pending_alarms = client.pending_alarms, []
                try:
                    msg, data = client.recv()
                    if msg == DVRIP_ALARM:
                        alarms.append(dvrip_json(data))
                except socket.timeout:
                    pass
                if any(alarm_is_motion_start(alarm) for alarm in alarms) and self.due():
                    client.sock.settimeout(HTTP_TIMEOUT)
                    self.save(client.snapshot(), "dvrip")
                    client.sock.settimeout(1.0)
        finally:
            client.close()


WORKER_KINDS = {"onvif": OnvifWorker, "dvrip": DvripWorker}


class MotionSupervisor:
    """Keeps one worker per monitored camera in step with config.json and motion.json."""

    def __init__(self, config_dir: Path, motion_dir: Path):
        self.config_dir = config_dir
        self.motion_dir = motion_dir
        self.board = StatusBoard(motion_dir)
        self.workers: dict[str, CameraWorker] = {}
        self.settings: dict = {}
        self.config_stamp = None
        self.last_prune = 0.0

    def _config_stamp(self):
        stamp = []
        for name in ("config.json", "motion.json", BRIDGE_CONFIG):
            try:
                st = (self.config_dir / name).stat()
                stamp.append((st.st_mtime_ns, st.st_size))
            except OSError:
                stamp.append(None)
        return tuple(stamp)

    def plan(self) -> dict:
        """Desired workers: {camera_id: (camera, source)}."""
        library = load_json(self.config_dir / "config.json", {"cameras": []})
        if not isinstance(library, dict):
            library = {"cameras": []}
        self.settings = ensure_motion_config(self.config_dir, library)
        self.config_stamp = self._config_stamp()
        if not self.settings.get("enabled"):
            return {}
        return {camera["id"]: (camera, motion_source(self.config_dir, camera))
                for camera in monitored_cameras(library, self.settings)}

    def stop_worker(self, camera_id: str):
        worker = self.workers.pop(camera_id)
        worker.stop_event.set()
        worker.join(timeout=HTTP_TIMEOUT + 2)

    def reload(self):
        desired = self.plan()
        for camera_id, worker in list(self.workers.items()):
            camera, source = desired.get(camera_id, (None, None))
            if camera is None or source != worker.source or camera.get("name") != worker.camera_name:
                self.stop_worker(camera_id)
        self.board.keep_only(set(desired))
        self.board.set_global(enabled=bool(self.settings.get("enabled")))
        for camera_id, (camera, source) in desired.items():
            if camera_id in self.workers:
                self.workers[camera_id].settings = self.settings
                continue
            kind = WORKER_KINDS.get(source["kind"])
            if kind is None:
                self.board.update(camera_id, name=camera.get("name") or "", source="none",
                                  listening=False, lastError=source.get("reason", "No motion source."))
                continue
            worker = kind(camera, source, self.motion_dir, self.board, self.settings)
            self.workers[camera_id] = worker
            worker.start()

    def prune(self):
        hours, max_files, _ = retention_settings(self.settings)
        prune_all(self.motion_dir, hours, max_files)
        self.last_prune = time.time()

    def run(self) -> int:
        # Signal handlers only work on the main thread; workers poll _STOP.
        signal.signal(signal.SIGTERM, _handle_signal)
        signal.signal(signal.SIGINT, _handle_signal)
        ensure_dirs(self.motion_dir)
        self.reload()
        self.prune()
        last_check = time.time()
        while not _STOP:
            time.sleep(1)
            now = time.time()
            if now - last_check >= CONFIG_CHECK_SEC:
                last_check = now
                if self._config_stamp() != self.config_stamp:
                    self.reload()
            if now - self.last_prune >= PRUNE_EVERY_SEC:
                self.prune()
        for camera_id in list(self.workers):
            self.stop_worker(camera_id)
        return 0


def camera_names(config_dir: Path) -> dict:
    library = load_json(config_dir / "config.json", {"cameras": []})
    cameras = library.get("cameras") if isinstance(library, dict) else []
    return {c["id"]: c.get("name") or "" for c in cameras or [] if isinstance(c, dict) and isinstance(c.get("id"), str)}


def cmd_list(config_dir: Path, motion_dir: Path) -> int:
    ensure_dirs(motion_dir)
    settings = load_json(config_dir / "motion.json", {})
    if not isinstance(settings, dict):
        settings = {}
    # Before the daemon migrates motion.json, the old single cameraId owns the root stills.
    legacy = settings.get("legacyCameraId") or settings.get("cameraId") or ""
    print(json.dumps(list_stills(motion_dir, camera_names(config_dir), legacy)))
    return 0


def cmd_status(config_dir: Path, motion_dir: Path) -> int:
    """Daemon status for the gallery, with current camera names; accepts the old flat format."""
    status = load_json(motion_dir / ".status.json", {})
    if not isinstance(status, dict):
        status = {}
    names = camera_names(config_dir)
    cameras = status.get("cameras")
    if isinstance(cameras, dict):
        for camera_id, entry in cameras.items():
            if isinstance(entry, dict) and camera_id in names:
                entry["name"] = names[camera_id]
    print(json.dumps(status))
    return 0


def cmd_once(config_dir: Path, motion_dir: Path, camera_id: str) -> int:
    supervisor = MotionSupervisor(config_dir, motion_dir)
    plan = supervisor.plan()
    if not camera_id and plan:
        camera_id = next(iter(plan))
    camera, source = plan.get(camera_id, (None, None))
    kind = WORKER_KINDS.get(source["kind"]) if source else None
    if kind is None:
        print(json.dumps({"ok": False, "error": "no motion source"}))
        return 1
    worker = kind(camera, source, motion_dir, supervisor.board, supervisor.settings)
    try:
        path = worker.capture_now("manual")
    except Exception as error:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": error.__class__.__name__}))
        return 1
    print(json.dumps({"ok": bool(path), "path": str(path) if path else None}))
    return 0 if path else 1


def cmd_prune(config_dir: Path, motion_dir: Path) -> int:
    library = load_json(config_dir / "config.json", {"cameras": [], "selectedId": ""})
    cfg = ensure_motion_config(config_dir, library if isinstance(library, dict) else {})
    hours, max_files, _ = retention_settings(cfg)
    print(json.dumps({"removed": prune_all(motion_dir, hours, max_files)}))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="yani.camera motion still helper")
    parser.add_argument("--list", action="store_true", help="list saved stills as JSON")
    parser.add_argument("--status", action="store_true", help="print listener status as JSON")
    parser.add_argument("--once", action="store_true", help="capture one snapshot now")
    parser.add_argument("--camera", default="", help="camera id for --once")
    parser.add_argument("--prune-only", action="store_true", help="apply retention and exit")
    parser.add_argument("--set-login", metavar="CAMERA", help="prompt for a camera's device (app) login and save it")
    parser.add_argument("--same-as", metavar="CAMERA", default="", help="with --set-login: try another camera's login")
    args = parser.parse_args(argv)
    config_dir, motion_dir = base_dirs()
    ensure_dirs(motion_dir)
    if args.list:
        return cmd_list(config_dir, motion_dir)
    if args.status:
        return cmd_status(config_dir, motion_dir)
    if args.once:
        return cmd_once(config_dir, motion_dir, args.camera)
    if args.set_login:
        return cmd_set_login(config_dir, args.set_login, copy_from=args.same_as)
    if args.prune_only:
        return cmd_prune(config_dir, motion_dir)
    return MotionSupervisor(config_dir, motion_dir).run()


if __name__ == "__main__":
    sys.exit(main())
