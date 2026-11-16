#!/usr/bin/env python3
"""Keep the cameras' clocks on the PC's time (run by yani-camera-clock.timer).

XMeye cameras keep time in whole seconds and keep their own sub-second phase
when the time is set, so a clock can only be moved by whole seconds. This finds
the moment a camera's second turns (polling its time), works out how far it is
from the PC, and if that is half a second or more, sets it right after a turn
so it lands within half a second of the PC. Their own NTP left them seconds
apart; the PC's clock is synchronised.

One DVRIP login per camera per run; a refused login is never retried here.
"""
from __future__ import annotations

import sys
import time
from datetime import datetime

import motiond

TIME_QUERY = 1452
TIME_SET = 1450
FORMAT = "%Y-%m-%d %H:%M:%S"
TICK_WAIT_SEC = 1.5  # a second always turns within this, however fast the camera answers


def query(client) -> tuple[float, float]:
    """The camera's time and the PC time at the middle of the request."""
    sent = time.time()
    client.send(TIME_QUERY, {"Name": "OPTimeQuery", "SessionID": client.session_id})
    _, reply = client.recv_reply(TIME_QUERY + 1)
    received = time.time()
    return datetime.strptime(reply["OPTimeQuery"], FORMAT).timestamp(), (sent + received) / 2


def wait_for_tick(client) -> tuple[float, float] | None:
    """Poll until the camera's second changes: (its new second, PC time then)."""
    first, _ = query(client)
    deadline = time.monotonic() + TICK_WAIT_SEC
    while time.monotonic() < deadline:
        value, at = query(client)
        if value != first:
            return value, at
        time.sleep(0.02)
    return None


def measure(client) -> float | None:
    """Camera minus PC, in seconds (about ±0.1 s)."""
    tick = wait_for_tick(client)
    return tick[0] - tick[1] if tick else None


def correct(client, tolerance: float = 0.5) -> tuple[float | None, float | None]:
    """Returns (offset before, offset after); after is None when nothing was changed."""
    before = measure(client)
    if before is None or abs(before) < tolerance:
        return before, None
    shift = round(before)
    tick = wait_for_tick(client)  # set right after a turn: the camera keeps its phase
    if not tick:
        return before, None
    client.send(TIME_SET, {"Name": "OPTimeSetting", "SessionID": client.session_id,
                           "OPTimeSetting": datetime.fromtimestamp(tick[0] - shift).strftime(FORMAT)})
    _, reply = client.recv_reply(TIME_SET + 1)
    if reply.get("Ret") not in (100, 515):
        return before, None
    time.sleep(0.3)
    return before, measure(client)


def main() -> int:
    config_dir, _ = motiond.base_dirs()
    library = motiond.load_json(config_dir / "config.json", {})
    status = 0
    for camera in (library.get("cameras") or []) if isinstance(library, dict) else []:
        if not isinstance(camera, dict):
            continue
        login = motiond.dvrip_login_for(config_dir, camera)
        if not login:
            continue
        name = str(camera.get("name") or camera.get("id"))[:40]
        client = motiond.DvripClient(login["host"], login["port"], login["user"], login["password"], timeout=10)
        try:
            client.connect()
            before, after = correct(client)
            if before is None:
                print(f"{name}: clock unreadable")
                status = 1
            elif after is None:
                print(f"{name}: {before:+.2f} s, left as it is")
            else:
                print(f"{name}: {before:+.2f} s, set to {after:+.2f} s")
        except motiond.DvripLoginError:
            print(f"{name}: login refused")
            status = 1
        except (OSError, ConnectionError, KeyError, ValueError) as error:
            print(f"{name}: {type(error).__name__}")
            status = 1
        finally:
            client.close()
    return status


if __name__ == "__main__":
    sys.exit(main())
