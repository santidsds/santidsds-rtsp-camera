"""Tests for motiond prune / list / credential helpers (no network)."""
import os
import tempfile
import time
import unittest
from pathlib import Path

import motiond


class CredentialTests(unittest.TestCase):
    def test_path_credentials_xm(self):
        url = (
            "rtsp://203.0.113.10:554/"
            "user=demo_password=demoPass_channel=0_stream=0.sdp?real_stream"
        )
        self.assertEqual(
            motiond.extract_path_credentials(url),
            ("demo", "demoPass"),
        )

    def test_path_credentials_missing(self):
        self.assertEqual(motiond.extract_path_credentials("rtsp://host/ch"), ("", ""))

    def test_credentials_prefers_fields(self):
        camera = {
            "url": "rtsp://h/user=a_password=b_ch",
            "username": "fielduser",
            "password": "fieldpass",
        }
        self.assertEqual(
            motiond.credentials_for(camera),
            ("fielduser", "fieldpass"),
        )


class FilenameTests(unittest.TestCase):
    def test_roundtrip(self):
        name = motiond.still_filename()
        self.assertTrue(name.endswith(".jpg"))
        self.assertIsNotNone(motiond.parse_still_time(name))

    def test_parse_rejects_junk(self):
        self.assertIsNone(motiond.parse_still_time("not-a-time.jpg"))


class PruneTests(unittest.TestCase):
    def test_retention_and_max_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            old = directory / "2020-01-01_00-00-00.jpg"
            old.write_bytes(b"x")
            ancient = time.time() - 48 * 3600
            os.utime(old, (ancient, ancient))
            for index in range(5):
                path = directory / f"2026-09-22_10-00-{index:02d}.jpg"
                path.write_bytes(b"y")
            removed = motiond.prune_stills(
                directory, retention_hours=24, max_files=3
            )
            remaining = sorted(p.name for p in directory.glob("*.jpg"))
            self.assertNotIn(old.name, remaining)
            self.assertEqual(len(remaining), 3)
            self.assertGreaterEqual(removed, 3)

    def test_missing_dir(self):
        self.assertEqual(
            motiond.prune_stills(Path("/nonexistent/motion-dir-xyz")), 0
        )


class ListTests(unittest.TestCase):
    def test_list_sorted_newest_first(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            a = directory / "2026-09-22_10-00-00.jpg"
            b = directory / "2026-09-22_11-00-00.jpg"
            a.write_bytes(b"a")
            b.write_bytes(b"b")
            os.utime(a, (1000, 1000))
            os.utime(b, (2000, 2000))
            items = motiond.list_stills(directory)
            self.assertEqual([i["name"] for i in items], [b.name, a.name])


if __name__ == "__main__":
    unittest.main()
