from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys


def main():
    # The portable app ships PortAudio's WASAPI build only.
    os.environ.pop("SD_ENABLE_ASIO", None)
    parser = argparse.ArgumentParser(description="Blah local dictation for Windows")
    parser.add_argument("--worker", choices=["speech", "cleanup"], help=argparse.SUPPRESS)
    parser.add_argument("--tray", action="store_true", help="Start with Settings hidden")
    parser.add_argument("--self-test", action="store_true", help="Check packaged UI and native engines without recording")
    parser.add_argument("--report", help="Write self-test results to this file")
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("The Windows frontend requires Windows; use Sources/Blah on macOS")
    if args.worker:
        # PyInstaller's windowed bootloader leaves Python's standard streams None,
        # even when the parent supplies inherited pipes. Restore those handles.
        import ctypes
        import msvcrt
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.GetStdHandle.argtypes = [wintypes.DWORD]
        kernel.GetStdHandle.restype = wintypes.HANDLE
        for name, identifier, mode in [("stdin", -10, "r"), ("stdout", -11, "w"), ("stderr", -12, "w")]:
            if getattr(sys, name) is None:
                handle = kernel.GetStdHandle(identifier & 0xffffffff)
                descriptor = msvcrt.open_osfhandle(handle, os.O_BINARY)
                setattr(sys, name, os.fdopen(descriptor, mode, encoding="utf-8", buffering=1))
        from blah.inference import worker
        worker(args.worker)
        return
    if args.self_test:
        import ctypes
        import tkinter as tk
        import sounddevice
        import pystray
        from blah.inference import runtime_directory
        from blah.platform import INPUT
        import tempfile
        from blah.app import App
        original_appdata = os.environ.get("LOCALAPPDATA")
        with tempfile.TemporaryDirectory(prefix="blah-self-test-") as directory:
            os.environ["LOCALAPPDATA"] = directory
            root = tk.Tk(); root.withdraw()
            app = App(root, start_services=False)
            root.update_idletasks()
            if len(app.tabs.tabs()) != 5: raise RuntimeError("Settings tabs missing")
            root.destroy()
        if original_appdata is None: os.environ.pop("LOCALAPPDATA", None)
        else: os.environ["LOCALAPPDATA"] = original_appdata
        report = {"platform": sys.platform, "python": sys.version, "inputBytes": ctypes.sizeof(INPUT), "engines": []}
        report["settingsUI"] = "passed"
        for kind, symbol in [("speech", "blah_transcribe"), ("cleanup", "blah_clean")]:
            lib = ctypes.CDLL(str(runtime_directory() / f"blah_{kind}.dll"))
            getattr(lib, symbol)
            report["engines"].append(kind)
        import base64
        import threading
        from blah.inference import Engine
        engine = Engine("speech")
        try:
            engine.call(dict(model="Z:/blah-self-test-missing.gguf", audio=base64.b64encode(b"\0" * 64000).decode()), threading.Event(), 15)
            raise RuntimeError("Missing model should be rejected")
        except RuntimeError as error:
            if "file not found" not in str(error).lower() and "file_not_found" not in str(error).lower():
                raise
            report["workerProtocol"] = "passed"
        finally:
            engine.close()
        text = json.dumps(report, indent=2)
        if args.report: Path(args.report).write_text(text, encoding="utf-8")
        elif sys.stdout: print(text)
        return
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
    kernel.CreateMutexW.restype = wintypes.HANDLE
    mutex = kernel.CreateMutexW(None, False, "Local\\Blah-Windows")
    if not mutex: raise ctypes.WinError(ctypes.get_last_error())
    if ctypes.get_last_error() == 183:
        from tkinter import messagebox
        messagebox.showinfo("Blah", "Blah is already running. Open Settings from its tray icon.")
        return
    # Keeps the mutex handle alive for the entire GUI lifetime.
    import tkinter as tk
    from tkinter import messagebox
    from blah.app import App
    root = tk.Tk()
    try:
        app = App(root)
        if args.tray: app.hide()
        root.mainloop()
    except Exception as error:
        messagebox.showerror("Blah could not start", str(error))
        root.destroy()
        raise
    finally:
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle(mutex)


if __name__ == "__main__":
    main()
