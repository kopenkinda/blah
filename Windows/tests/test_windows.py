import ctypes
import importlib.util
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import patch
import queue

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


@unittest.skipUnless(sys.platform == "win32", "Windows integration")
class WindowsIntegration(unittest.TestCase):
    def test_input_structure_and_key_names(self):
        from blah.platform import INPUT, key_name
        self.assertEqual(ctypes.sizeof(INPUT), 40 if ctypes.sizeof(ctypes.c_void_p) == 8 else 28)
        self.assertEqual(key_name(0xA3), "Right Ctrl")
        self.assertTrue(key_name(0x50))

    def test_priority_skips_disconnected_microphones(self):
        from blah.audio import choose_microphone
        devices = [dict(id="built-in"), dict(id="usb")]
        self.assertEqual(choose_microphone(["missing", "usb", "built-in"], devices)["id"], "usb")
        self.assertEqual(choose_microphone(["missing"], devices)["id"], "built-in")
        with self.assertRaises(RuntimeError): choose_microphone([], [])

    def test_cancel_before_worker_start(self):
        from blah.inference import Engine
        from blah.models import Cancelled
        event = threading.Event(); event.set()
        engine = Engine("speech")
        with self.assertRaises(Cancelled): engine.call({}, event, 1)
        self.assertIsNone(engine.process)

    def test_worker_reports_missing_dll_or_model(self):
        from blah.inference import Engine
        import base64
        engine = Engine("speech")
        try:
            with self.assertRaises(RuntimeError):
                engine.call(dict(model="Z:/missing-model.gguf", audio=base64.b64encode(b"\0" * 64000).decode()), threading.Event(), 20)
        finally: engine.close()

    def test_no_paste_into_unrelated_window(self):
        from blah import platform
        with patch.object(platform, "clipboard") as clipboard, patch.object(platform, "send_keys") as send:
            self.assertFalse(platform.paste("test", None, threading.Event()))
            clipboard.assert_called_once_with("test")
            send.assert_not_called()

    def test_keyboard_hold_repeat_and_chord_passthrough(self):
        from blah import platform as p
        events = queue.Queue(); keyboard = p.Keyboard(events, key=0x50)
        data = p.KBD(0x50, 0, 0, 0, 0)
        with patch.object(p.user32, "GetAsyncKeyState", return_value=0), \
             patch.object(p.user32, "GetForegroundWindow", return_value=123), \
             patch.object(p.user32, "CallNextHookEx", return_value=55), \
             patch.object(p, "send_keys") as send:
            self.assertEqual(keyboard._hook(0, 0x100, ctypes.addressof(data)), 1)
            self.assertEqual(events.get_nowait()[0], "press")
            keyboard._hook(0, 0x100, ctypes.addressof(data))
            self.assertTrue(events.empty())
            data.vkCode = 0x41
            self.assertEqual(keyboard._hook(0, 0x100, ctypes.addressof(data)), 55)
            self.assertEqual(events.get_nowait()[0], "chord")
            send.assert_called_once_with([(0x50, False)])
            data.vkCode = 0x50
            self.assertEqual(keyboard._hook(0, 0x101, ctypes.addressof(data)), 55)
            self.assertEqual(events.get_nowait()[0], "release")

    def test_transcript_retained_if_history_and_clipboard_both_fail(self):
        from blah.app import App
        from blah.core import Preferences
        from unittest.mock import Mock
        app = App.__new__(App)
        app.work, app.events = queue.Queue(), queue.Queue()
        app.speech = Mock(); app.speech.call.return_value = "hello"
        app.history = Mock(); app.history.append.side_effect = OSError("history locked")
        app.work.put(dict(prefs=Preferences(cleanup=False), cancel=threading.Event(), target=None, audio=b"\0" * 64000))
        app.work.put(None)
        with patch("blah.app.win.paste", side_effect=OSError("clipboard locked")):
            app._worker()
        results = []
        while not app.events.empty(): results.append(app.events.get_nowait())
        text, unsaved, notice = next(value for event, value in results if event == "result")
        self.assertEqual(text, "hello")
        self.assertEqual(unsaved["rawText"], "hello")
        self.assertIn("clipboard locked", notice)

    def test_recorder_keeps_audio_on_overflow_interruption_and_cap(self):
        from blah import audio
        from unittest.mock import Mock
        streams = []
        def stream(**kwargs):
            streams.append(kwargs["callback"]); return Mock()
        with patch.object(audio.sd, "RawInputStream", side_effect=stream), \
             patch.object(audio, "MAX_FRAMES", 4):
            recorder = audio.Recorder(); recorder.start(dict(index=0))
            capture, block = streams[-1], bytes(8)
            capture(block, 2, None, Mock(input_overflow=True))
            self.assertIsNone(recorder.error)
            capture(block, 2, None, None)
            self.assertTrue(recorder.full)
            capture(block, 2, None, None)
            self.assertEqual(recorder.stop(), block * 2)
            recorder.start(dict(index=0)); capture = streams[-1]
            capture(block, 2, None, None)
            capture(block, 2, None, Mock(input_overflow=False))
            self.assertIsNotNone(recorder.error)
            self.assertEqual(recorder.stop(), block * 2)

    def test_paste_target_ignores_blah_and_taskbar(self):
        from blah import platform as p
        import os
        def owner(pid):
            def fill(hwnd, out): out._obj.value = pid; return 1
            return fill
        def window_class(name):
            def fill(hwnd, buffer, size): buffer.value = name; return len(name)
            return fill
        with patch.object(p.user32, "GetForegroundWindow", return_value=77):
            with patch.object(p.user32, "GetWindowThreadProcessId", side_effect=owner(os.getpid())):
                self.assertIsNone(p.paste_target())
            with patch.object(p.user32, "GetWindowThreadProcessId", side_effect=owner(os.getpid() + 1)):
                with patch.object(p.user32, "GetClassNameW", side_effect=window_class("Shell_TrayWnd")):
                    self.assertIsNone(p.paste_target())
                with patch.object(p.user32, "GetClassNameW", side_effect=window_class("Notepad")):
                    self.assertEqual(p.paste_target(), 77)

    def test_clipboard_has_owner_and_transfers_memory(self):
        from blah import platform as p
        memory = ctypes.create_string_buffer(128)
        with patch.object(p.user32, "CreateWindowExW", return_value=123), \
             patch.object(p.user32, "DestroyWindow") as destroy, \
             patch.object(p.user32, "OpenClipboard", return_value=True) as opened, \
             patch.object(p.user32, "EmptyClipboard", return_value=True), \
             patch.object(p.user32, "SetClipboardData", return_value=456), \
             patch.object(p.user32, "CloseClipboard"), \
             patch.object(p.kernel32, "GlobalAlloc", return_value=456), \
             patch.object(p.kernel32, "GlobalLock", return_value=ctypes.addressof(memory)), \
             patch.object(p.kernel32, "GlobalUnlock"), \
             patch.object(p.kernel32, "GlobalFree") as free:
            p.clipboard("Привет")
            opened.assert_called_once_with(123)
            destroy.assert_called_once_with(123)
            free.assert_not_called()
            self.assertEqual(memory.raw[:14], "Привет\0".encode("utf-16-le"))


if __name__ == "__main__": unittest.main()
