"""Opt-in end-to-end tests: BLAH_TEST_MODELS points to verified GGUF files.

BLAH_TEST_AUDIO points to whisper.cpp's public samples/jfk.wav (mono 16 kHz PCM).
No personal audio is recorded or stored by these tests.
"""
import array
import base64
import os
from pathlib import Path
import sys
import threading
import unittest
import wave
from contextlib import ExitStack
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


@unittest.skipUnless(sys.platform == "win32" and os.environ.get("BLAH_TEST_MODELS") and os.environ.get("BLAH_TEST_AUDIO"),
                     "Set BLAH_TEST_MODELS and BLAH_TEST_AUDIO for real-model integration tests")
class ModelIntegration(unittest.TestCase):
    def test_parakeet_and_s1_mini(self):
        from blah.inference import Engine
        from blah.models import CATALOG
        directory = Path(os.environ["BLAH_TEST_MODELS"]).resolve()
        with wave.open(os.environ["BLAH_TEST_AUDIO"]) as wav:
            self.assertEqual((wav.getnchannels(), wav.getsampwidth(), wav.getframerate()), (1, 2, 16000))
            pcm = array.array("h", wav.readframes(wav.getnframes()))
        audio = array.array("f", (s / 32768 for s in pcm)).tobytes()
        cancel = threading.Event()
        speech, cleanup = Engine("speech"), Engine("cleanup")
        stack = ExitStack()
        if os.environ.get("BLAH_TEST_EXE"):
            stack.enter_context(patch.object(sys, "frozen", True, create=True))
            stack.enter_context(patch.object(sys, "executable", str(Path(os.environ["BLAH_TEST_EXE"]).resolve())))
        try:
            raw = speech.call(dict(model=str(directory / CATALOG[0].filename),
                audio=base64.b64encode(audio).decode()), cancel, 600)
            self.assertIn("fellow americans", raw.casefold())
            self.assertIn("country", raw.casefold())
            cleaned = cleanup.call(dict(model=str(directory / CATALOG[3].filename), text=raw,
                styling="semi-casual", structure="lists", context="general"), cancel, 30)
            self.assertTrue(cleaned.strip())
            self.assertNotIn("<|im_start|>", cleaned)
            self.assertIn("country", cleaned.casefold())
            # Second request uses the already-loaded model and a fresh context.
            again = cleanup.call(dict(model=str(directory / CATALOG[3].filename), text="hello um how are you",
                styling="formal", structure="prose", context="general"), cancel, 30)
            self.assertTrue(again.strip())
            print("\nParakeet:", raw, "\nS1-mini:", cleaned, "\nSecond cleanup:", again)
        finally:
            speech.close(); cleanup.close()
            stack.close()


if __name__ == "__main__": unittest.main()
