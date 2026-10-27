import dataclasses
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from blah.core import Gesture, History, Preferences, Replacement, replace_text
from blah.models import Cancelled, Model, download


class Replacements(unittest.TestCase):
    def test_unicode_boundaries_match_swift(self):
        rule = Replacement("salute", "salut")
        self.assertEqual(replace_text("Salute, salute! SALUTE saluted présalute saluté", [rule]),
                         "salut, salut! salut saluted présalute saluté")
        self.assertEqual(replace_text("кот котик _кот кот2", [Replacement("кот", "cat")]), "cat котик _кот кот2")

    def test_literal_order_case_and_empty(self):
        self.assertEqual(replace_text("a.b axb", [Replacement("a.b", "$1\\hello")]), "$1\\hello axb")
        self.assertEqual(replace_text("Salute salute", [Replacement("salute", "salut", True)]), "Salute salut")
        self.assertEqual(replace_text("saluted", [Replacement("salute", "salut", wholeWords=False)]), "salutd")
        self.assertEqual(replace_text("salute!", [Replacement(), Replacement("salute", "")]), "!")
        self.assertEqual(replace_text("salute", [Replacement("salute", "salut"), Replacement("salut", "bonjour")]), "bonjour")


class Gestures(unittest.TestCase):
    def test_hold_and_repeated_keydown(self):
        g = Gesture()
        self.assertEqual(g.press(10), "start")
        self.assertIsNone(g.press(10.1))
        self.assertEqual(g.tick(10.23), "show")
        self.assertEqual(g.release(11), "finish")
        self.assertEqual(g.mode, "none")

    def test_single_tap_is_discarded(self):
        g = Gesture(); g.press(10); g.release(10.05)
        self.assertIsNone(g.tick(10.3))
        self.assertEqual(g.tick(10.36), "discard")
        self.assertIsNone(g.release(11))

    def test_double_tap_locks_then_tap_finishes(self):
        g = Gesture(); g.press(10); g.release(10.05)
        self.assertEqual(g.press(10.2), "show")
        self.assertEqual(g.mode, "locked")
        self.assertIsNone(g.release(10.25))
        self.assertEqual(g.press(12), "finish")
        self.assertIsNone(g.release(12.05))

    def test_escape_cancels_all_capture_modes(self):
        for mode in ("held", "waiting", "locked"):
            g = Gesture(); g.mode = mode
            self.assertEqual(g.cancel(), "discard")
            self.assertIsNone(g.cancel())

    def test_second_press_after_double_tap_deadline_restarts(self):
        g = Gesture(); g.press(10); g.release(10.05)
        self.assertEqual(g.press(10.4), "restart")
        self.assertEqual(g.mode, "held")
        self.assertEqual(g.release(11), "finish")


class Storage(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_preferences_round_trip(self):
        p = Preferences(replacements=[Replacement("привет", "hello")], microphonePriority=["disconnected", "USB"])
        path = self.path / "preferences.json"; p.save(path)
        self.assertEqual(dataclasses.asdict(Preferences.load(path)), dataclasses.asdict(p))

    def test_corrupt_preferences_not_overwritten(self):
        path = self.path / "preferences.json"; path.write_text('{"key": 20}')
        with self.assertRaises(ValueError): Preferences.load(path)
        self.assertEqual(path.read_text(), '{"key": 20}')

    def test_history_retention_and_external_edits(self):
        h = History(self.path / "history.jsonl"); h.limit = 3
        for i in range(4): h.append(dict(text=str(i), rawText=str(i)))
        self.assertEqual([e["text"] for e in h.load()], ["1", "2", "3"])
        h.path.write_text('{"text":"manual","rawText":"raw"}', encoding="utf-8")
        h.append(dict(text="new", rawText="new"))
        self.assertEqual([e["text"] for e in h.load()], ["manual", "new"])

    def test_bad_history_never_replaced(self):
        h = History(self.path / "history.jsonl")
        h.path.write_text('{"text":"valid","rawText":"valid"}\nBAD\n', encoding="utf-8")
        before = h.path.read_bytes()
        with self.assertRaisesRegex(ValueError, "line 2"):
            h.append(dict(text="new", rawText="new"))
        self.assertEqual(h.path.read_bytes(), before)


class Downloads(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)
        self.data = b"small test model"
        self.model = Model("Test", "test.gguf", "repo", "revision", len(self.data), hashlib.sha256(self.data).hexdigest())

    def tearDown(self): self.temp.cleanup()

    def opener(self, *args, **kwargs):
        response = io.BytesIO(self.data); response.status = 200
        return response

    def test_verified_atomic_install(self):
        download(self.model, self.path, threading.Event(), opener=self.opener)
        self.assertEqual((self.path / "test.gguf").read_bytes(), self.data)
        self.assertEqual(len(list(self.path.iterdir())), 1)

    def test_bad_checksum_and_cancel_leave_no_partial_models(self):
        for model, cancel, error in [(dataclasses.replace(self.model, sha256="bad"), threading.Event(), ValueError),
                                     (self.model, threading.Event(), Cancelled)]:
            if error is Cancelled: cancel.set()
            with self.assertRaises(error): download(model, self.path, cancel, opener=self.opener)
            self.assertEqual(list(self.path.iterdir()), [])

    def test_never_overwrite_shared_model(self):
        target = self.path / self.model.filename; target.write_bytes(b"shared")
        with self.assertRaises(FileExistsError): download(self.model, self.path, threading.Event(), opener=self.opener)
        self.assertEqual(target.read_bytes(), b"shared")


if __name__ == "__main__": unittest.main()
