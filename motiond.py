#!/usr/bin/env python3
"""Always-on motion still capture for yani.camera (ONVIF PullPoint + snapshot).

Stdlib only. Reads camera credentials from config.json (never logs them).
CLI:
  (default)     run capture loop until SIGTERM
  --list        print JSON array of saved stills (newest first)
  --once        one-shot: pull briefly / take a manual snapshot (debug)
  --prune-only  apply retention then exit
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import signal
import socket
import ssl
import sys
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


def ensure_motion_config(config_dir: Path, library) -> dict:
    path = config_dir / "motion.json"
    data = load_json(path, None)
    cameras = library.get("cameras") or []
    selected = library.get("selectedId") or ""
    default_cam = selected if any(c.get("id") == selected for c in cameras) else (
        cameras[0]["id"] if cameras else ""
    )
    if not isinstance(data, dict):
        data = {
            "enabled": True,
            "cameraId": default_cam,
            "retentionHours": DEFAULT_RETENTION_HOURS,
            "maxFiles": DEFAULT_MAX_FILES,
            "minIntervalSec": DEFAULT_MIN_INTERVAL_SEC,
        }
        config_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(data, indent=2) + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
        return data
    data.setdefault("enabled", True)
    data.setdefault("cameraId", default_cam)
    data.setdefault("retentionHours", DEFAULT_RETENTION_HOURS)
    data.setdefault("maxFiles", DEFAULT_MAX_FILES)
    data.setdefault("minIntervalSec", DEFAULT_MIN_INTERVAL_SEC)
    if data.get("enabled") and not data.get("cameraId") and default_cam:
        data["cameraId"] = default_cam
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(data, indent=2) + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    return data


def find_camera(library, camera_id: str):
    for camera in library.get("cameras") or []:
        if camera.get("id") == camera_id:
            return camera
    return None


def camera_host(url: str) -> str:
    host = urlsplit(url).hostname
    if not host:
        raise ValueError("camera URL has no host")
    return host


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


def list_stills(motion_dir: Path) -> list[dict]:
    if not motion_dir.is_dir():
        return []
    items = []
    for path in motion_dir.iterdir():
        if not path.is_file() or path.suffix.lower() not in (".jpg", ".jpeg"):
            continue
        when = parse_still_time(path.name)
        items.append(
            {
                "name": path.name,
                "path": str(path),
                "mtime": path.stat().st_mtime,
                "time": when.strftime("%H:%M:%S") if when else "",
                "date": when.strftime("%Y-%m-%d") if when else "",
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


def write_status(motion_dir: Path, **fields):
    ensure_dirs(motion_dir)
    path = motion_dir / ".status.json"
    current = load_json(path, {})
    if not isinstance(current, dict):
        current = {}
    current.update(fields)
    current["updated"] = datetime.now(timezone.utc).isoformat()
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(current) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _http(method: str, url: str, data: bytes | None = None, headers: dict | None = None) -> bytes:
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    context = ssl.create_default_context()
    # LAN cameras often use self-signed certs on 8443; we only use http here.
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT, context=context) as resp:
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


def event_looks_like_motion(reply: str) -> bool:
    lowered = reply.lower()
    if "motion" not in lowered and "cellmotion" not in lowered and "tamper" not in lowered:
        # Pull empty / unrelated — treat explicit true motion rules only
        if "rule" not in lowered:
            return False
    # Heuristic: presence of motion topic or State true near motion
    if re.search(r"cellmotion|tns1:RuleEngine/CellMotionDetector", lowered):
        return True
    if re.search(r"topic[^>]*motion", lowered):
        return True
    # Generic motion topic
    if "motion" in lowered and (
        "true" in lowered or "<tt:Data" in reply or "wsnt:Message" in reply
    ):
        # Avoid counting pure topic property dumps without messages
        if "PullMessagesResponse" in reply or "wsnt:NotificationMessage" in reply:
            return True
    if "NotificationMessage" in reply and "motion" in lowered:
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


class MotionLoop:
    def __init__(self, config_dir: Path, motion_dir: Path):
        self.config_dir = config_dir
        self.motion_dir = motion_dir
        self.library = {}
        self.motion_cfg = {}
        self.host = ""
        self.user = ""
        self.password = ""
        self.last_save = 0.0
        self.last_prune = 0.0

    def reload(self):
        library = load_json(self.config_dir / "config.json", {"cameras": [], "selectedId": ""})
        if not isinstance(library, dict):
            library = {"cameras": [], "selectedId": ""}
        self.library = library
        self.motion_cfg = ensure_motion_config(self.config_dir, library)
        camera = find_camera(library, self.motion_cfg.get("cameraId") or "")
        if not camera:
            self.host = ""
            write_status(self.motion_dir, enabled=bool(self.motion_cfg.get("enabled")),
                         camera="", lastError="No camera bound for motion capture.")
            return False
        self.host = camera_host(camera["url"])
        self.user, self.password = credentials_for(camera)
        write_status(
            self.motion_dir,
            enabled=bool(self.motion_cfg.get("enabled")),
            camera=camera.get("name") or "",
            cameraId=camera.get("id") or "",
            lastError="",
        )
        return True

    def retention(self) -> tuple[int, int, int]:
        cfg = self.motion_cfg or {}
        try:
            hours = int(cfg.get("retentionHours") or DEFAULT_RETENTION_HOURS)
        except (TypeError, ValueError):
            hours = DEFAULT_RETENTION_HOURS
        try:
            max_files = int(cfg.get("maxFiles") or DEFAULT_MAX_FILES)
        except (TypeError, ValueError):
            max_files = DEFAULT_MAX_FILES
        try:
            min_interval = int(cfg.get("minIntervalSec") or DEFAULT_MIN_INTERVAL_SEC)
        except (TypeError, ValueError):
            min_interval = DEFAULT_MIN_INTERVAL_SEC
        return hours, max_files, max(1, min_interval)

    def maybe_prune(self, force: bool = False):
        now = time.time()
        if not force and now - self.last_prune < PRUNE_EVERY_SEC:
            return
        self.last_prune = now
        hours, max_files, _ = self.retention()
        prune_stills(self.motion_dir, hours, max_files, now=now)

    def capture_snapshot(self, reason: str = "motion") -> Path | None:
        hours, max_files, min_interval = self.retention()
        now = time.time()
        if now - self.last_save < min_interval:
            return None
        if not self.host:
            if not self.reload():
                return None
        try:
            url = get_snapshot_url(self.host, self.user, self.password)
            data = fetch_snapshot(url)
            path = save_still(self.motion_dir, data)
            self.last_save = time.time()
            self.maybe_prune(force=True)
            write_status(
                self.motion_dir,
                lastEvent=datetime.now().astimezone().isoformat(),
                lastError="",
                lastReason=reason,
                count=len(list_stills(self.motion_dir)),
            )
            return path
        except Exception as error:  # noqa: BLE001 — status only, no secrets
            write_status(self.motion_dir, lastError=str(error.__class__.__name__))
            return None

    def run(self) -> int:
        signal.signal(signal.SIGTERM, _handle_signal)
        signal.signal(signal.SIGINT, _handle_signal)
        ensure_dirs(self.motion_dir)
        self.reload()
        self.maybe_prune(force=True)
        if not self.motion_cfg.get("enabled"):
            write_status(self.motion_dir, enabled=False, lastError="Motion capture disabled.")
            while not _STOP:
                time.sleep(IDLE_POLL_SEC)
                # pick up config edits
                self.reload()
                if self.motion_cfg.get("enabled"):
                    break
        sub_addr = None
        expires = 0.0
        backoff = 2
        while not _STOP:
            try:
                if not self.motion_cfg.get("enabled"):
                    if sub_addr:
                        unsubscribe(sub_addr)
                        sub_addr = None
                    time.sleep(IDLE_POLL_SEC)
                    self.reload()
                    continue
                if not self.host and not self.reload():
                    time.sleep(IDLE_POLL_SEC)
                    continue
                now = time.time()
                if sub_addr is None or now >= expires - RENEW_MARGIN_SEC:
                    if sub_addr:
                        unsubscribe(sub_addr)
                        sub_addr = None
                    event_xaddr = resolve_event_xaddr(self.host)
                    sub_addr, expires = create_pull_subscription(event_xaddr)
                    backoff = 2
                    write_status(self.motion_dir, listening=True, lastError="")
                reply = pull_messages(sub_addr, timeout_sec=PULL_TIMEOUT_SEC)
                expires = time.time() + 110
                if event_looks_like_motion(reply):
                    self.capture_snapshot("onvif")
                self.maybe_prune()
                # cheap config reload every few pulls handled by prune timer path
                if int(now) % 60 < PULL_TIMEOUT_SEC:
                    self.reload()
            except Exception as error:  # noqa: BLE001
                write_status(
                    self.motion_dir,
                    listening=False,
                    lastError=str(error.__class__.__name__),
                )
                if sub_addr:
                    unsubscribe(sub_addr)
                    sub_addr = None
                time.sleep(backoff)
                backoff = min(60, backoff * 2)
        if sub_addr:
            unsubscribe(sub_addr)
        write_status(self.motion_dir, listening=False)
        return 0


def cmd_list(motion_dir: Path) -> int:
    ensure_dirs(motion_dir)
    print(json.dumps(list_stills(motion_dir)))
    return 0


def cmd_once(config_dir: Path, motion_dir: Path) -> int:
    loop = MotionLoop(config_dir, motion_dir)
    loop.reload()
    path = loop.capture_snapshot("manual")
    loop.maybe_prune(force=True)
    print(json.dumps({"ok": bool(path), "path": str(path) if path else None}))
    return 0 if path else 1


def cmd_prune(config_dir: Path, motion_dir: Path) -> int:
    library = load_json(config_dir / "config.json", {"cameras": [], "selectedId": ""})
    cfg = ensure_motion_config(config_dir, library if isinstance(library, dict) else {})
    try:
        hours = int(cfg.get("retentionHours") or DEFAULT_RETENTION_HOURS)
    except (TypeError, ValueError):
        hours = DEFAULT_RETENTION_HOURS
    try:
        max_files = int(cfg.get("maxFiles") or DEFAULT_MAX_FILES)
    except (TypeError, ValueError):
        max_files = DEFAULT_MAX_FILES
    removed = prune_stills(motion_dir, hours, max_files)
    print(json.dumps({"removed": removed}))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="yani.camera motion still helper")
    parser.add_argument("--list", action="store_true", help="list saved stills as JSON")
    parser.add_argument("--once", action="store_true", help="capture one snapshot now")
    parser.add_argument("--prune-only", action="store_true", help="apply retention and exit")
    args = parser.parse_args(argv)
    config_dir, motion_dir = base_dirs()
    ensure_dirs(motion_dir)
    if args.list:
        return cmd_list(motion_dir)
    if args.once:
        return cmd_once(config_dir, motion_dir)
    if args.prune_only:
        return cmd_prune(config_dir, motion_dir)
    return MotionLoop(config_dir, motion_dir).run()


if __name__ == "__main__":
    sys.exit(main())
