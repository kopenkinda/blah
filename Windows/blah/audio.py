from __future__ import annotations

import array
import io
import math
import struct
import threading
import wave
import winsound
import sounddevice as sd


def microphones() -> list[dict]:
    # WASAPI exposes full Unicode names and supports Windows' shared-mode conversion.
    # Retain name + API, rather than unstable enumeration indices, in preferences.
    sd._terminate()
    sd._initialize()
    apis = sd.query_hostapis()
    devices = []
    for index, device in enumerate(sd.query_devices()):
        if device["max_input_channels"] and apis[device["hostapi"]]["name"] == "Windows WASAPI":
            name = device["name"]
            ordinal = sum(d["name"] == name for d in devices)
            devices.append(dict(id=f"WASAPI:{name}:{ordinal}", name=name, index=index))
    return devices


def choose_microphone(priority: list[str], devices: list[dict]) -> dict:
    for identifier in priority:
        for device in devices:
            if device["id"] == identifier:
                return device
    if devices:
        return devices[0]
    raise RuntimeError("No microphone is available. Connect one and enable microphone access in Windows Settings.")


# 15 minutes of 16 kHz mono float audio (~58 MB); recording finishes at the cap.
MAX_FRAMES = 16000 * 60 * 15


class Recorder:
    def __init__(self):
        self.stream = None
        self.chunks = []
        self.level = 0.0
        self.frames = 0
        self.error = None
        self.full = False

    def start(self, device: dict):
        self.chunks, self.frames, self.error, self.full = [], 0, None, False
        def capture(data, frames, timing, status):
            # A dropped buffer (input overflow) is harmless; keep recording.
            if status and not status.input_overflow:
                self.error = "Audio capture was interrupted; check the microphone connection."
            if self.full:
                return
            chunk = bytes(data)
            self.chunks.append(chunk)
            self.frames += frames
            self.full = self.frames >= MAX_FRAMES
            samples = array.array("f", chunk)
            self.level = min(1.0, math.sqrt(sum(x * x for x in samples) / max(1, len(samples))) * 6)
        try:
            self.stream = sd.RawInputStream(device=device["index"], samplerate=16000, channels=1,
                dtype="float32", callback=capture, blocksize=960,
                extra_settings=sd.WasapiSettings(auto_convert=True))
            self.stream.start()
        except Exception:
            if self.stream:
                self.stream.close()
            self.stream = None
            raise

    def stop(self) -> bytes:
        if self.stream:
            self.stream.stop()
            self.stream.close()
            self.stream = None
        self.level = 0.0
        audio = b"".join(self.chunks)
        self.chunks = []
        # The caller reports self.error; audio captured before an interruption is kept.
        return audio


SOUNDS = ["Off", "Pop", "Bottle", "Tink", "Frog"]


def play_sound(name: str, volume: float):
    if name == "Off":
        return
    frequency = {"Pop": 440, "Bottle": 660, "Tink": 1100, "Frog": 220}.get(name, 440)
    def play():
        data = io.BytesIO()
        with wave.open(data, "wb") as wav:
            wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            wav.writeframes(b"".join(struct.pack("<h", int(12000 * max(0, min(1, volume)) *
                math.sin(2 * math.pi * frequency * i / 16000) * (1 - i / 1600) ** 2)) for i in range(1600)))
        try:
            winsound.PlaySound(data.getvalue(), winsound.SND_MEMORY | winsound.SND_NODEFAULT)
        except RuntimeError:
            pass
    threading.Thread(target=play, daemon=True).start()
