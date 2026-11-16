"""Tests for camclock.py with a simulated camera clock (whole seconds, own phase)."""
import json
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path

import camclock
import motiond
import sdclip


class FakeClock:
    """A camera whose seconds turn at its own phase; setting the time keeps that phase."""

    def __init__(self, offset: float):
        self.base = offset           # camera time = PC time + base (seconds turn at its own phase)
        self.session_id = "0x1"
        self.sets = 0
        self.reply = None

    def now(self) -> float:
        return time.time() + self.base

    def send(self, msg, body):
        if msg == camclock.TIME_QUERY:
            shown = int(self.now())
            self.reply = {"Ret": 100, "OPTimeQuery": datetime.fromtimestamp(shown).strftime(camclock.FORMAT)}
        elif msg == camclock.TIME_SET:
            wanted = datetime.strptime(body["OPTimeSetting"], camclock.FORMAT).timestamp()
            self.base += wanted - int(self.now())   # whole seconds: the phase stays
            self.sets += 1
            self.reply = {"Ret": 100}

    def recv_reply(self, msg):
        time.sleep(0.005)
        return msg, self.reply


class CamClockTest(unittest.TestCase):
    def test_measures_the_offset(self):
        for offset in (-3.0, -1.3, 0.4):
            self.assertAlmostEqual(camclock.measure(FakeClock(offset)), offset, delta=0.05)

    def test_moves_a_clock_by_whole_seconds_to_within_half_a_second(self):
        for offset, expected in ((-3.01, -0.01), (-1.3, -0.3), (2.6, -0.4), (0.7, -0.3)):
            clock = FakeClock(offset)
            before, after = camclock.correct(clock)
            self.assertAlmostEqual(before, offset, delta=0.05)
            self.assertAlmostEqual(after, expected, delta=0.06, msg=f"from {offset}")
            self.assertEqual(clock.sets, 1)

    def test_a_close_clock_is_left_alone(self):
        clock = FakeClock(-0.3)
        before, after = camclock.correct(clock)
        self.assertIsNone(after)
        self.assertEqual(clock.sets, 0)


class RefusingCamera:
    """A camera that refuses the login (wrong password); counts the attempts."""
    attempts = 0

    def __init__(self, *args, **kwargs):
        pass

    def connect(self):
        RefusingCamera.attempts += 1
        raise motiond.DvripLoginError(203)

    def close(self):
        pass


class RefusedLoginTest(unittest.TestCase):
    def test_a_refused_login_is_not_tried_again_until_a_new_one_is_saved(self):
        with tempfile.TemporaryDirectory() as tmp:
            config, root = Path(tmp) / "config", Path(tmp) / "clips"
            config.mkdir()
            camera = {"id": "a" * 32, "name": "Yard", "url": "rtsp://127.0.0.1:8554/yard"}
            (config / "config.json").write_text(json.dumps({"cameras": [camera]}))
            (config / "go2rtc.private.json").write_text(json.dumps(
                {"streams": {"yard": "dvrip://admin:old@192.0.2.10:34567?channel=0&subtype=0"}}))
            RefusingCamera.attempts = 0
            message, ok = camclock.keep(config, camera, root, RefusingCamera)
            self.assertEqual((message, ok), ("Yard: login refused", False))
            self.assertTrue((root / camera["id"] / sdclip.LOGIN_REFUSED).exists(), "shared with SD playback")
            for _ in range(3):  # the hourly timer, later on
                message, ok = camclock.keep(config, camera, root, RefusingCamera)
                self.assertIn("skipped", message)
            self.assertEqual(RefusingCamera.attempts, 1, "one failed login, not one per hour")
            (root / camera["id"] / sdclip.LOGIN_REFUSED).unlink()  # a new login was saved (or one worked)
            camclock.keep(config, camera, root, RefusingCamera)
            self.assertEqual(RefusingCamera.attempts, 2)


if __name__ == "__main__":
    unittest.main()
