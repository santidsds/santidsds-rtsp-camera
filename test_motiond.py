"""Tests for motiond helpers, multi-camera storage and the DVRIP client (no real network)."""
import json
import os
import socket
import struct
import threading
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


def _note(topic, name, value, op="Changed"):
    return (
        "<wsnt:NotificationMessage><wsnt:Topic>" + topic + "</wsnt:Topic>"
        '<wsnt:Message><tt:Message PropertyOperation="' + op + '"><tt:Data>'
        '<tt:SimpleItem Name="' + name + '" Value="' + value + '" />'
        "</tt:Data></tt:Message></wsnt:Message></wsnt:NotificationMessage>"
    )


class MotionEventTests(unittest.TestCase):
    def wrap(self, *notes):
        return "<tev:PullMessagesResponse>" + "".join(notes) + "</tev:PullMessagesResponse>"

    def test_false_state_is_not_motion(self):
        reply = self.wrap(
            _note("tns1:RuleEngine/CellMotionDetector/Motion", "IsMotion", "false", "Initialized"),
            _note("tns1:VideoSource/MotionAlarm", "State", "false"),
        )
        self.assertFalse(motiond.event_looks_like_motion(reply))

    def test_true_motion(self):
        reply = self.wrap(_note("tns1:RuleEngine/CellMotionDetector/Motion", "IsMotion", "true"))
        self.assertTrue(motiond.event_looks_like_motion(reply))

    def test_true_non_motion_topic_ignored(self):
        reply = self.wrap(_note("tns1:Device/Trigger/DigitalInput", "LogicalState", "true"))
        self.assertFalse(motiond.event_looks_like_motion(reply))

    def test_empty(self):
        self.assertFalse(motiond.event_looks_like_motion(self.wrap()))


def _write(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data))


BRIDGE = {"streams": {
    "icsee": "dvrip://admin:p%40ss@192.0.2.3:34567?channel=0&subtype=0",
    "icsee_baja": "dvrip://admin:p%40ss@192.0.2.3:34567?channel=0&subtype=1",
    "icsee_plugin": "ffmpeg:icsee_baja#video=h264#audio=aac#input=icsee_input",
    "loop_a": "loop_b", "loop_b": "loop_a",
    "direct": "rtsp://192.0.2.9:554/user=u_password=pw_channel=0.sdp",
}}


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.config = Path(self.tmp.name)
        _write(self.config / motiond.BRIDGE_CONFIG, BRIDGE)

    def tearDown(self):
        self.tmp.cleanup()

    def test_bridge_chain_resolves_to_dvrip(self):
        source = motiond.motion_source(self.config, {"url": "rtsp://127.0.0.1:8554/icsee_plugin"})
        self.assertEqual(source, {"kind": "dvrip", "host": "192.0.2.3", "port": 34567,
                                  "user": "admin", "password": "p@ss"})

    def test_bridge_to_rtsp_uses_onvif_on_real_host(self):
        source = motiond.motion_source(self.config, {"url": "rtsp://127.0.0.1:8554/direct"})
        self.assertEqual((source["kind"], source["host"], source["user"], source["password"]),
                         ("onvif", "192.0.2.9", "u", "pw"))

    def test_loopback_without_bridge_has_no_source(self):
        for url in ("rtsp://127.0.0.1:8554/unknown", "rtsp://127.0.0.1:8554/loop_a"):
            self.assertEqual(motiond.motion_source(self.config, {"url": url})["kind"], "none")

    def test_direct_camera_uses_onvif(self):
        source = motiond.motion_source(self.config, {"url": "rtsp://192.0.2.2:554/s", "username": "a", "password": "b"})
        self.assertEqual((source["kind"], source["host"], source["user"]), ("onvif", "192.0.2.2", "a"))


class MotionConfigTests(unittest.TestCase):
    def test_single_camera_config_migrates_to_all(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp)
            _write(config / "motion.json", {"enabled": True, "cameraId": "cam1", "maxFiles": 50})
            data = motiond.ensure_motion_config(config, {})
            self.assertEqual(data["cameraIds"], "all")
            self.assertEqual(data["legacyCameraId"], "cam1")
            self.assertNotIn("cameraId", data)
            self.assertEqual(data["maxFiles"], 50)
            self.assertEqual(json.loads((config / "motion.json").read_text())["cameraIds"], "all")
            self.assertEqual(oct((config / "motion.json").stat().st_mode & 0o777), "0o600")

    def test_monitored_cameras_filters_and_rejects_unsafe_ids(self):
        library = {"cameras": [{"id": "a"}, {"id": "../etc"}, {"id": "b"}]}
        self.assertEqual([c["id"] for c in motiond.monitored_cameras(library, {"cameraIds": "all"})], ["a", "b"])
        self.assertEqual([c["id"] for c in motiond.monitored_cameras(library, {"cameraIds": ["b"]})], ["b"])
        with self.assertRaises(ValueError):
            motiond.camera_dir(Path("/tmp"), "../escape")


class MultiCameraStorageTests(unittest.TestCase):
    def test_list_attributes_legacy_and_folders(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "2026-11-14_10-00-00.jpg").write_bytes(b"old")
            (root / "cam2").mkdir()
            (root / "cam2" / "2026-11-14_11-00-00.jpg").write_bytes(b"new")
            os.utime(root / "2026-11-14_10-00-00.jpg", (1000, 1000))
            os.utime(root / "cam2" / "2026-11-14_11-00-00.jpg", (2000, 2000))
            items = motiond.list_stills(root, {"cam1": "Front", "cam2": "<b>Back</b>"}, "cam1")
            self.assertEqual([(i["cameraId"], i["cameraName"]) for i in items],
                             [("cam2", "<b>Back</b>"), ("cam1", "Front")])

    def test_prune_applies_per_camera(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for folder in (root, root / "cam2"):
                folder.mkdir(exist_ok=True)
                for index in range(4):
                    (folder / f"2026-11-14_10-00-0{index}.jpg").write_bytes(b"x")
            motiond.prune_all(root, retention_hours=24, max_files=2)
            self.assertEqual(len(list(root.glob("*.jpg"))), 2)
            self.assertEqual(len(list((root / "cam2").glob("*.jpg"))), 2)

    def test_status_board_tracks_cameras(self):
        with tempfile.TemporaryDirectory() as tmp:
            board = motiond.StatusBoard(Path(tmp))
            board.update("a", name="Front", listening=True)
            board.update("b", name="Back", listening=False, lastError="ConnectionRefusedError")
            board.keep_only({"a", "b"})
            status = json.loads((Path(tmp) / ".status.json").read_text())
            self.assertTrue(status["listening"])
            self.assertEqual(status["camera"], "Front, Back")
            self.assertEqual(status["lastError"], "ConnectionRefusedError")
            board.keep_only({"a"})
            status = json.loads((Path(tmp) / ".status.json").read_text())
            self.assertEqual(list(status["cameras"]), ["a"])


class DvripTests(unittest.TestCase):
    def test_sofia_hash_known_value(self):
        self.assertEqual(motiond.sofia_hash(""), "tlJwpbo6")

    def test_alarm_parsing(self):
        start = {"AlarmInfo": {"Event": "VideoMotion", "Status": "Start", "Channel": 0}}
        self.assertTrue(motiond.alarm_is_motion_start(start))
        self.assertFalse(motiond.alarm_is_motion_start({"AlarmInfo": {"Event": "VideoMotion", "Status": "Stop"}}))
        self.assertFalse(motiond.alarm_is_motion_start({"AlarmInfo": {"Event": "StorageFailure", "Status": "Start"}}))
        self.assertTrue(motiond.alarm_is_motion_start({"AlarmInfo": {"Event": "appEventHumanDetectAlarm", "Status": "Start"}}))

    def test_worker_saves_still_on_alarm(self):
        jpeg = b"\xff\xd8" + b"\x11" * 3000 + b"\xff\xd9"
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        port = server.getsockname()[1]
        seen = {}

        def packet(msg, payload):
            return motiond._DVRIP_HEADER.pack(255, 0, 7, 0, msg, len(payload)) + payload

        def body(data):
            return json.dumps(data).encode() + b"\x0a\x00"

        def serve():
            conn, _ = server.accept()
            client = motiond.DvripClient("127.0.0.1", port, "", "")
            client.sock = conn
            try:
                msg, data = client.recv()
                seen["login"] = motiond.dvrip_json(data)
                conn.sendall(packet(1001, body({"Ret": 100, "SessionID": "0x00000007", "AliveInterval": 30})))
                msg, data = client.recv()
                seen["guard"] = msg
                conn.sendall(packet(1501, body({"Ret": 100})))
                conn.sendall(packet(1504, body({"AlarmInfo": {"Event": "VideoMotion", "Status": "Start"}})))
                msg, data = client.recv()
                seen["snapshot"] = motiond.dvrip_json(data)
                conn.sendall(packet(1561, jpeg[:1000]) + packet(1561, jpeg[1000:]))
                conn.recv(1024)
            except OSError:
                pass
            finally:
                conn.close()

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        with tempfile.TemporaryDirectory() as tmp:
            motion = Path(tmp)
            board = motiond.StatusBoard(motion)
            source = {"kind": "dvrip", "host": "127.0.0.1", "port": port, "user": "admin", "password": ""}
            worker = motiond.DvripWorker({"id": "cam2", "name": "Back"}, source, motion, board, {"minIntervalSec": 5})
            worker.start()
            deadline = time.time() + 5
            while time.time() < deadline and not list((motion / "cam2").glob("*.jpg")):
                time.sleep(0.05)
            worker.stop_event.set()
            worker.join(timeout=5)
            server.close()
            stills = list((motion / "cam2").glob("*.jpg"))
            self.assertEqual(len(stills), 1, "alarm produced one still")
            self.assertEqual(stills[0].read_bytes(), jpeg, "multi-packet JPEG reassembled")
            self.assertEqual(oct(stills[0].stat().st_mode & 0o777), "0o600")
            self.assertEqual(seen["login"]["PassWord"], "tlJwpbo6")
            self.assertEqual(seen["login"]["UserName"], "admin")
            self.assertEqual(seen["guard"], motiond.DVRIP_GUARD)
            self.assertEqual(seen["snapshot"]["Name"], "OPSNAP")
            status = json.loads((motion / ".status.json").read_text())
            self.assertEqual(status["cameras"]["cam2"]["source"], "dvrip")
            self.assertEqual(status["cameras"]["cam2"].get("lastError"), "")


class FakeLoginClient:
    accept = True
    tried = []

    def __init__(self, host, port, user, password):
        FakeLoginClient.tried.append((host, port, user, password))

    def connect(self):
        if not FakeLoginClient.accept:
            raise motiond.DvripLoginError(203)

    def close(self):
        pass


class SetLoginTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.config = Path(self.tmp.name)
        _write(self.config / "config.json", {"version": 2, "selectedId": "c1", "cameras": [
            {"id": "c1", "name": "Camera 1", "url": "rtsp://192.0.2.2:554/s", "username": "", "password": ""},
            {"id": "c2", "name": "Camera 2", "url": "rtsp://127.0.0.1:8554/icsee_plugin", "username": "", "password": ""}]})
        _write(self.config / motiond.BRIDGE_CONFIG, BRIDGE)
        FakeLoginClient.tried = []

    def tearDown(self):
        self.tmp.cleanup()

    def run_set(self, ref, accept=True, user=""):
        FakeLoginClient.accept = accept
        return motiond.cmd_set_login(self.config, ref, ask=lambda _: user, ask_secret=lambda _: "s3cret",
                                     client_class=FakeLoginClient)

    def test_success_saves_private_login_and_tries_once(self):
        self.assertEqual(self.run_set("camera 1"), 0)
        self.assertEqual(FakeLoginClient.tried, [("192.0.2.2", 34567, "admin", "s3cret")])
        path = self.config / motiond.LOGINS_FILE
        self.assertEqual(json.loads(path.read_text()), {"c1": {"user": "admin", "password": "s3cret"}})
        self.assertEqual(oct(path.stat().st_mode & 0o777), "0o600")
        login = motiond.dvrip_login_for(self.config, {"id": "c1", "url": "rtsp://192.0.2.2:554/s"})
        self.assertEqual((login["host"], login["user"]), ("192.0.2.2", "admin"))

    def test_refused_login_saves_nothing(self):
        self.assertEqual(self.run_set("Camera 1", accept=False), 1)
        self.assertEqual(len(FakeLoginClient.tried), 1)
        self.assertFalse((self.config / motiond.LOGINS_FILE).exists())

    def test_bridge_camera_needs_no_login(self):
        self.assertEqual(self.run_set("c2"), 0)
        self.assertEqual(FakeLoginClient.tried, [])
        login = motiond.dvrip_login_for(self.config, {"id": "c2", "url": "rtsp://127.0.0.1:8554/icsee_plugin"})
        self.assertEqual(login["host"], "192.0.2.3")

    def test_copy_login_from_bridge_camera(self):
        FakeLoginClient.accept = True
        code = motiond.cmd_set_login(self.config, "Camera 1", ask=None, ask_secret=None,
                                     client_class=FakeLoginClient, copy_from="Camera 2")
        self.assertEqual(code, 0)
        self.assertEqual(FakeLoginClient.tried, [("192.0.2.2", 34567, "admin", "p@ss")])
        saved = json.loads((self.config / motiond.LOGINS_FILE).read_text())["c1"]
        self.assertEqual(saved, {"user": "admin", "password": "p@ss"})

    def test_copy_login_from_unknown_camera_tries_nothing(self):
        code = motiond.cmd_set_login(self.config, "Camera 1", ask=None, ask_secret=None,
                                     client_class=FakeLoginClient, copy_from="garage")
        self.assertEqual(code, 2)
        self.assertEqual(FakeLoginClient.tried, [])

    def test_unknown_camera(self):
        self.assertEqual(self.run_set("garage"), 2)
        self.assertEqual(FakeLoginClient.tried, [])


if __name__ == "__main__":
    unittest.main()
