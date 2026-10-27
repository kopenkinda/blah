from __future__ import annotations

import array
import base64
import ctypes
import json
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time

from .models import Cancelled


def runtime_directory() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / "runtimes"
    return Path(__file__).resolve().parents[2] / ".build/windows/runtimes"


class Engine:
    """One serialized worker per engine. Restart after cancel, crash, or deadline."""
    def __init__(self, kind: str):
        self.kind = kind
        self.process = None
        self.responses = queue.Queue()
        self.lock = threading.Lock()

    def call(self, request: dict, cancel: threading.Event, timeout: float) -> str:
        with self.lock:
            if cancel.is_set():
                raise Cancelled()
            if self.process is None or self.process.poll() is not None:
                self.close()
                command = [sys.executable, "--worker", self.kind] if getattr(sys, "frozen", False) else [
                    sys.executable, str(Path(__file__).resolve().parents[1] / "main.py"), "--worker", self.kind]
                self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, text=True, encoding="utf-8", bufsize=1,
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                self.responses = queue.Queue()
                def read(process, responses):
                    try:
                        for line in process.stdout:
                            responses.put(line)
                    finally:
                        responses.put(None)
                threading.Thread(target=read, args=(self.process, self.responses), daemon=True).start()
            try:
                self.process.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
                self.process.stdin.flush()
                deadline = time.monotonic() + timeout
                while True:
                    if cancel.is_set():
                        raise Cancelled()
                    if time.monotonic() >= deadline:
                        raise TimeoutError(f"{self.kind.capitalize()} took too long")
                    try:
                        line = self.responses.get(timeout=0.05)
                    except queue.Empty:
                        continue
                    if line is None:
                        raise RuntimeError(f"{self.kind.capitalize()} worker stopped unexpectedly")
                    response = json.loads(line)
                    if "error" in response:
                        raise RuntimeError(response["error"])
                    return response["text"].strip()
            except BaseException:
                self.close()
                raise

    def close(self):
        if self.process:
            if self.process.poll() is None:
                self.process.kill()
            self.process.wait(timeout=5)
            self.process.stdin.close()
            self.process.stdout.close()
            self.process = None


def worker(kind: str) -> None:
    # Native engines have separate GGML versions; they never share a process.
    # Redirect native diagnostics away from the JSON protocol descriptor.
    import os
    output = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8", buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    library = None
    for line in sys.stdin:
        try:
            request = json.loads(line)
            if library is None:
                library = ctypes.CDLL(str(runtime_directory() / f"blah_{kind}.dll"))
            if kind == "speech":
                fn = library.blah_transcribe
                fn.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_float), ctypes.c_int]
                fn.restype = ctypes.c_char_p
                audio = array.array("f")
                audio.frombytes(base64.b64decode(request["audio"]))
                audio.extend([0.0] * max(0, 16000 - len(audio)))
                buffer = (ctypes.c_float * len(audio)).from_buffer(audio)
                response = fn(request["model"].encode("utf-8"), buffer, len(audio))
            else:
                fn = library.blah_clean
                fn.argtypes = [ctypes.c_char_p] * 5
                fn.restype = ctypes.c_char_p
                response = fn(*(request[k].encode("utf-8") for k in ("model", "text", "styling", "structure", "context")))
            status, text = response.decode("utf-8").split("\n", 1)
            output.write(json.dumps({"text" if status == "OK" else "error": text}, ensure_ascii=False) + "\n")
        except Exception as error:
            output.write(json.dumps({"error": str(error)}) + "\n")
