from __future__ import annotations

import base64
import copy
import math
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
import tkinter as tk
from tkinter import ttk, filedialog, messagebox

from .core import Preferences, Replacement, Gesture, History, app_directory, history_entry, replace_text
from .models import CATALOG, Cancelled, download
from .inference import Engine
from .audio import Recorder, microphones, choose_microphone, play_sound, SOUNDS
from . import platform as win


POSITIONS = ["Top left", "Top center", "Top right", "Center left", "Center", "Center right",
             "Bottom left", "Bottom center", "Bottom right"]


class Overlay:
    def __init__(self, root):
        self.window = tk.Toplevel(root)
        self.window.withdraw()
        self.window.overrideredirect(True)
        self.window.attributes("-topmost", True)
        self.window.attributes("-transparentcolor", "#ff00ff")
        self.canvas = tk.Canvas(self.window, width=300, height=126, bg="#ff00ff", highlightthickness=0)
        self.canvas.pack()
        self.window.update_idletasks()
        import ctypes as C
        from ctypes import wintypes as W
        win.user32.GetParent.argtypes = [W.HWND]
        win.user32.GetParent.restype = W.HWND
        win.user32.GetWindowLongPtrW.argtypes = [W.HWND, C.c_int]
        win.user32.GetWindowLongPtrW.restype = C.c_ssize_t
        win.user32.SetWindowLongPtrW.argtypes = [W.HWND, C.c_int, C.c_ssize_t]
        win.user32.SetWindowLongPtrW.restype = C.c_ssize_t
        hwnd = win.user32.GetParent(self.window.winfo_id())
        style = win.user32.GetWindowLongPtrW(hwnd, -20)
        win.user32.SetWindowLongPtrW(hwnd, -20, style | 0x08000000 | 0x80 | 0x20)

    def draw(self, text: str | None, level: float, position: int):
        if not text:
            self.window.withdraw()
            return
        width, height = self.window.winfo_screenwidth(), self.window.winfo_screenheight()
        col, row = position % 3, position // 3
        x = [24, (width - 300) // 2, width - 324][col]
        y = [24, (height - 126) // 2, height - 180][row]
        self.window.geometry(f"300x126+{max(0, x)}+{max(0, y)}")
        self.canvas.delete("all")
        self.canvas.create_oval(112, 4, 188, 80, fill="#16253d", outline="#599dff", width=2)
        phase = time.monotonic() * 1.4
        for i in range(48):
            a = i * 2.39996
            z = 1 - 2 * (i + 0.5) / 48
            r = math.sqrt(1 - z * z)
            px = 150 + 32 * r * math.cos(a + phase) * (1 + level * 0.15)
            py = 42 + 32 * z
            size = 1.5 + level * 2
            self.canvas.create_oval(px-size, py-size, px+size, py+size, fill="#85ccff", outline="")
        self.canvas.create_rectangle(0, 87, 300, 126, fill="#16253d", outline="")
        self.canvas.create_text(150, 106, text=text[:100], fill="white", width=290, font=("Segoe UI", 10))
        self.window.deiconify()


class App:
    def __init__(self, root: tk.Tk, start_services=True):
        self.root = root
        self.directory = app_directory()
        self.prefs_path = self.directory / "preferences.json"
        self.prefs = Preferences.load(self.prefs_path)
        self.history = History(self.directory / "history.jsonl")
        self.events = queue.Queue()
        self.work = queue.Queue()
        self.pending = []
        self.current = None
        self.closing = False
        self.last = ""
        self.unsaved = None
        self.stage = ""
        self.notice = ""
        self.notice_until = 0
        self.target = None
        self.paste_last_target = None
        self.gesture = Gesture()
        self.recorder = Recorder()
        self.overlay = Overlay(root)
        self.speech, self.cleanup = Engine("speech"), Engine("cleanup")
        self.download_cancel = threading.Event()
        self.downloading = False
        self.devices = []
        self.next_devices = 0
        self.key_select = False
        self.keyboard = win.Keyboard(self.events, self.prefs.key)
        self.root.title("Blah — local dictation")
        self.root.geometry("820x650")
        self.root.minsize(700, 520)
        self.root.protocol("WM_DELETE_WINDOW", self.hide)
        self._build_settings()
        if start_services:
            self._tray()
            self.keyboard.start()
            self.worker_thread = threading.Thread(target=self._worker, daemon=True)
            self.worker_thread.start()
            self.root.after(25, self.tick)
        self.refresh_history()
        self.notify("Hold " + win.key_name(self.prefs.key) + " to dictate. Download a speech model in Models.", 8)

    def notify(self, text: str, seconds=6):
        self.notice, self.notice_until = text, time.monotonic() + seconds
        self.status.set(text)

    def save(self):
        try:
            self.prefs.save(self.prefs_path)
        except Exception as error:
            self.notify("Could not save settings: " + str(error), 10)

    def _tray(self):
        import pystray
        from PIL import Image, ImageDraw
        image = Image.new("RGBA", (64, 64))
        draw = ImageDraw.Draw(image)
        draw.ellipse((3, 3, 61, 61), fill="#16253d", outline="#599dff", width=4)
        for x, top in [(20, 23), (28, 15), (36, 20), (44, 27)]:
            draw.line((x, top, x, 64-top), fill="#85ccff", width=4)
        def post(name):
            return lambda *args: self.events.put((name, None))
        self.tray = pystray.Icon("Blah", image, "Blah — local dictation", pystray.Menu(
            pystray.MenuItem("Settings", post("settings"), default=True),
            pystray.MenuItem("Paste last transcript", post("paste_last")),
            pystray.MenuItem("Transcript History", post("history")),
            pystray.MenuItem("Quit", post("quit"))))
        self.tray.run_detached()

    def show(self, history=False):
        self.root.deiconify()
        self.root.lift()
        if history:
            self.tabs.select(self.history_tab)
            self.refresh_history()

    def hide(self):
        self.root.withdraw()

    def _build_settings(self):
        style = ttk.Style()
        style.theme_use("vista")
        top = ttk.Frame(self.root, padding=16)
        top.pack(fill="both", expand=True)
        ttk.Label(top, text="Blah", font=("Segoe UI", 22, "bold")).pack(anchor="w")
        ttk.Label(top, text="Local speech recognition · hold to dictate · double-tap for hands-free").pack(anchor="w", pady=(0, 12))
        self.tabs = ttk.Notebook(top)
        self.tabs.pack(fill="both", expand=True)
        general, mics, models, replacements, self.history_tab = [ttk.Frame(self.tabs, padding=12) for _ in range(5)]
        for frame, title in zip((general, mics, models, replacements, self.history_tab), ("General", "Microphones", "Models", "Replacements", "Transcript History")):
            self.tabs.add(frame, text=title)
        self.status = tk.StringVar(value="Ready")
        ttk.Label(top, textvariable=self.status, wraplength=760).pack(fill="x", pady=(10, 0))
        self.key_button = ttk.Button(general, text="Dictation key: " + win.key_name(self.prefs.key), command=self.select_key)
        self.key_button.pack(anchor="w", pady=4)
        ttk.Label(general, text="Press a key to change it. Escape cancels. Caps Lock cannot be used.\nCombinations with the dictation key continue to work.").pack(anchor="w", pady=4)
        self.speech_choice = ttk.Combobox(general, state="readonly", values=[m.name for m in CATALOG[:3]], width=55)
        self.speech_choice.current(next((i for i, m in enumerate(CATALOG[:3]) if m.filename == self.prefs.speechModel), 0))
        self.speech_choice.pack(anchor="w", pady=4)
        self.speech_choice.bind("<<ComboboxSelected>>", lambda e: self.update_pref("speechModel", CATALOG[self.speech_choice.current()].filename))
        enabled = tk.BooleanVar(value=self.prefs.cleanup)
        ttk.Checkbutton(general, text="Format with S1-mini (English, local)", variable=enabled,
            command=lambda: self.update_pref("cleanup", enabled.get())).pack(anchor="w", pady=4)
        for name, label, values in [("styling", "Style", ["casual", "semi-casual", "semi-formal", "formal"]),
                                    ("structure", "Structure", ["prose", "lists"]), ("context", "Context", ["general", "email"])]:
            row = ttk.Frame(general); row.pack(fill="x", pady=3)
            ttk.Label(row, text=label, width=14).pack(side="left")
            value = tk.StringVar(value=getattr(self.prefs, name))
            box = ttk.Combobox(row, textvariable=value, values=values, state="readonly", width=22)
            box.pack(side="left")
            box.bind("<<ComboboxSelected>>", lambda e, n=name, v=value: self.update_pref(n, v.get()))
        row = ttk.Frame(general); row.pack(fill="x", pady=4)
        ttk.Label(row, text="Orb position", width=14).pack(side="left")
        position = ttk.Combobox(row, values=POSITIONS, state="readonly", width=22)
        position.current(self.prefs.orbPosition); position.pack(side="left")
        position.bind("<<ComboboxSelected>>", lambda e: self.update_pref("orbPosition", position.current()))
        ttk.Button(row, text="Preview", command=lambda: self.notify("Ready to dictate", 3)).pack(side="left", padx=8)
        for starting in (True, False):
            field = "startSound" if starting else "stopSound"
            row = ttk.Frame(general); row.pack(fill="x", pady=3)
            ttk.Label(row, text="Start sound" if starting else "Stop sound", width=14).pack(side="left")
            value = tk.StringVar(value=getattr(self.prefs, field))
            box = ttk.Combobox(row, textvariable=value, values=SOUNDS, state="readonly", width=10); box.pack(side="left")
            box.bind("<<ComboboxSelected>>", lambda e, f=field, v=value: self.update_pref(f, v.get()))
            volume = tk.DoubleVar(value=getattr(self.prefs, field + "Volume"))
            ttk.Scale(row, from_=0, to=1, variable=volume, length=130,
                command=lambda v, f=field: self.update_pref(f + "Volume", float(v))).pack(side="left", padx=8)
            ttk.Button(row, text="Preview", command=lambda v=value, vol=volume: play_sound(v.get(), vol.get())).pack(side="left")
        startup = tk.BooleanVar(value=win.startup_enabled())
        def login():
            command = subprocess.list2cmdline([sys.executable, "--tray"] if getattr(sys, "frozen", False) else [
                sys.executable, str(Path(__file__).resolve().parents[1] / "main.py"), "--tray"])
            try:
                win.set_startup(startup.get(), command)
            except OSError as error:
                self.notify(str(error)); startup.set(win.startup_enabled())
        ttk.Checkbutton(general, text="Launch at login", variable=startup, command=login).pack(anchor="w", pady=5)

        ttk.Label(mics, text="First available microphone wins. Disconnected microphones are remembered.").pack(anchor="w")
        self.mic_list = tk.Listbox(mics, height=12); self.mic_list.pack(fill="both", expand=True, pady=8)
        row = ttk.Frame(mics); row.pack(fill="x")
        ttk.Button(row, text="Move up", command=lambda: self.move_mic(-1)).pack(side="left")
        ttk.Button(row, text="Move down", command=lambda: self.move_mic(1)).pack(side="left", padx=5)
        ttk.Button(row, text="Windows microphone privacy", command=lambda: os.startfile("ms-settings:privacy-microphone")).pack(side="right")

        row = ttk.Frame(models); row.pack(fill="x")
        self.model_path = tk.StringVar(value=self.prefs.modelDirectory)
        ttk.Entry(row, textvariable=self.model_path).pack(side="left", fill="x", expand=True)
        ttk.Button(row, text="Choose folder", command=self.choose_models).pack(side="left", padx=5)
        ttk.Button(row, text="Apply", command=lambda: self.update_pref("modelDirectory", self.model_path.get())).pack(side="left")
        ttk.Label(models, text="Model weights download separately. Existing GGUF files can be reused.\nDownloads are verified by size and SHA-256 before installation.").pack(anchor="w", pady=12)
        for model in CATALOG:
            row = ttk.Frame(models); row.pack(fill="x", pady=8)
            ttk.Label(row, text=f"{model.name}\n{model.size / 1e6:.0f} MB", width=49).pack(side="left")
            ttk.Button(row, text="Download", command=lambda m=model: self.download_model(m)).pack(side="right")
        self.download_progress = tk.DoubleVar()
        ttk.Progressbar(models, variable=self.download_progress, maximum=1).pack(fill="x", pady=8)
        ttk.Button(models, text="Cancel download", command=self.download_cancel.set).pack(anchor="w")

        self.rule_list = tk.Listbox(replacements, height=8)
        self.rule_list.pack(fill="both", expand=True)
        self.rule_list.bind("<<ListboxSelect>>", lambda e: self.load_rule())
        self.find, self.replacement = tk.StringVar(), tk.StringVar()
        for label, variable in [("Find", self.find), ("Replace with", self.replacement)]:
            ttk.Label(replacements, text=label).pack(anchor="w", pady=(6, 0))
            ttk.Entry(replacements, textvariable=variable).pack(fill="x")
        self.match_case, self.whole_words = tk.BooleanVar(), tk.BooleanVar(value=True)
        ttk.Checkbutton(replacements, text="Match case", variable=self.match_case).pack(anchor="w")
        ttk.Checkbutton(replacements, text="Whole words", variable=self.whole_words).pack(anchor="w")
        row = ttk.Frame(replacements); row.pack(fill="x", pady=6)
        for label, command in [("Add", lambda: self.edit_rule("add")), ("Update", lambda: self.edit_rule("update")),
                               ("Delete", lambda: self.edit_rule("delete")), ("Move up", lambda: self.edit_rule("up")),
                               ("Move down", lambda: self.edit_rule("down"))]:
            ttk.Button(row, text=label, command=command).pack(side="left", padx=2)
        self.refresh_rules()

        row = ttk.Frame(self.history_tab); row.pack(fill="x")
        self.search = tk.StringVar()
        ttk.Entry(row, textvariable=self.search).pack(side="left", fill="x", expand=True)
        self.search.trace_add("write", lambda *args: self.refresh_history())
        ttk.Button(row, text="Reload", command=self.refresh_history).pack(side="left", padx=4)
        self.history_list = tk.Listbox(self.history_tab, height=7)
        self.history_list.pack(fill="both", expand=True, pady=6)
        self.history_list.bind("<<ListboxSelect>>", lambda e: self.display_entry())
        self.history_text = tk.Text(self.history_tab, height=9, wrap="word", state="disabled")
        self.history_text.pack(fill="both", expand=True)
        row = ttk.Frame(self.history_tab); row.pack(fill="x", pady=8)
        ttk.Button(row, text="Copy transcript", command=self.copy_history).pack(side="left")
        ttk.Button(row, text="Open history file", command=self.open_history).pack(side="left", padx=5)
        ttk.Button(row, text="Open data folder", command=lambda: self.open_folder(self.directory)).pack(side="left")

    def open_folder(self, path):
        path.mkdir(parents=True, exist_ok=True)
        os.startfile(str(path))

    def open_history(self):
        if not self.history.path.exists():
            self.notify("History is empty")
        else:
            os.startfile(str(self.history.path))

    def update_pref(self, name, value):
        if name == "modelDirectory" and not str(value).strip():
            self.notify("Choose a model folder first"); return
        setattr(self.prefs, name, value)
        self.save()

    def choose_models(self):
        folder = filedialog.askdirectory(initialdir=self.prefs.modelDirectory)
        if folder:
            self.model_path.set(folder); self.update_pref("modelDirectory", folder)

    def select_key(self):
        if self.gesture.mode != "none" or self.pending:
            self.notify("Finish dictation before changing the key"); return
        self.key_select = self.keyboard.capture_key = True
        self.key_button.configure(text="Press a key… Escape cancels")

    def move_mic(self, offset):
        selected = self.mic_list.curselection()
        if not selected or self.gesture.mode != "none":
            return
        index = selected[0]; other = index + offset
        if 0 <= other < len(self.prefs.microphonePriority):
            p = self.prefs.microphonePriority; p[index], p[other] = p[other], p[index]
            self.save(); self.render_mics(); self.mic_list.selection_set(other)

    def render_mics(self):
        self.mic_list.delete(0, "end")
        available = {d["id"]: d for d in self.devices}
        for identifier in self.prefs.microphonePriority:
            name = available.get(identifier, {}).get("name", identifier.removeprefix("WASAPI:").rsplit(":", 1)[0])
            self.mic_list.insert("end", name + ("" if identifier in available else " (disconnected)"))

    def refresh_devices(self):
        self.devices = microphones()
        changed = False
        for device in self.devices:
            if device["id"] not in self.prefs.microphonePriority:
                self.prefs.microphonePriority.append(device["id"]); changed = True
        if changed:
            self.save()
        self.render_mics()

    def refresh_rules(self):
        self.rule_list.delete(0, "end")
        for rule in self.prefs.replacements:
            self.rule_list.insert("end", f"{rule.find} → {rule.replacement}")

    def load_rule(self):
        selected = self.rule_list.curselection()
        if selected:
            rule = self.prefs.replacements[selected[0]]
            self.find.set(rule.find); self.replacement.set(rule.replacement)
            self.match_case.set(rule.matchCase); self.whole_words.set(rule.wholeWords)

    def edit_rule(self, action):
        selected = self.rule_list.curselection()
        index = selected[0] if selected else -1
        rules = self.prefs.replacements
        rule = Replacement(self.find.get(), self.replacement.get(), self.match_case.get(), self.whole_words.get())
        if action == "add": rules.append(rule)
        elif index >= 0:
            if action == "update": rules[index] = rule
            elif action == "delete": rules.pop(index)
            else:
                other = index + (-1 if action == "up" else 1)
                if 0 <= other < len(rules): rules[index], rules[other] = rules[other], rules[index]
        self.save(); self.refresh_rules()

    def refresh_history(self):
        try:
            entries = self.history.load()
            if self.unsaved: entries.append(self.unsaved)
            query = self.search.get().casefold()
            self.entries = [e for e in reversed(entries) if query in (e["text"] + e["rawText"]).casefold()]
            self.history_list.delete(0, "end")
            for entry in self.entries:
                self.history_list.insert("end", entry.get("createdAt", "")[:19] + "  " + entry["text"].replace("\n", " ")[:85])
        except Exception as error:
            self.notify(str(error), 10)

    def selected_entry(self):
        selected = self.history_list.curselection()
        return self.entries[selected[0]] if selected else None

    def display_entry(self):
        entry = self.selected_entry()
        if entry:
            text = f"{entry.get('formattingStatus', '')}\n\n{entry['text']}\n\nOriginal transcript\n{entry['rawText']}"
            self.history_text.configure(state="normal"); self.history_text.delete("1.0", "end")
            self.history_text.insert("1.0", text); self.history_text.configure(state="disabled")

    def copy_history(self):
        entry = self.selected_entry()
        if entry:
            try: win.clipboard(entry["text"]); self.notify("Copied")
            except Exception as error: self.notify(str(error))

    def download_model(self, model):
        if self.downloading:
            self.notify("A model download is already running"); return
        self.downloading = True; self.download_cancel.clear(); self.download_progress.set(0)
        directory = Path(self.prefs.modelDirectory)
        self.notify("Downloading " + model.name, 10)
        def run():
            try:
                download(model, directory, self.download_cancel, lambda p: self.events.put(("progress", p)))
                self.events.put(("download_done", model.name + " installed"))
            except Cancelled: self.events.put(("download_done", "Download cancelled"))
            except Exception as error: self.events.put(("download_done", str(error)))
        threading.Thread(target=run, daemon=True).start()

    def action(self, action):
        if action == "restart":
            self.action("discard")
            self.action("start")
            return
        if action == "start":
            try:
                if self.key_select: raise RuntimeError("Finish selecting a key first")
                if not (Path(self.prefs.modelDirectory) / self.prefs.speechModel).is_file():
                    raise RuntimeError("Download or select a speech model in Settings → Models")
                self.refresh_devices()
                self.recorder.start(choose_microphone(self.prefs.microphonePriority, self.devices))
                self.shown = False
            except Exception as error:
                self.gesture.cancel(); self.notify(str(error), 8)
        elif action == "show":
            if not getattr(self, "shown", False):
                self.shown = True; play_sound(self.prefs.startSound, self.prefs.startSoundVolume)
        elif action in ("finish", "discard"):
            try:
                error, full = self.recorder.error, self.recorder.full
                audio = self.recorder.stop()
                if getattr(self, "shown", False): play_sound(self.prefs.stopSound, self.prefs.stopSoundVolume)
                if action == "finish" and error: self.notify(error + " Transcribing what was recorded.", 8)
                elif action == "finish" and full: self.notify("Recording reached the 15-minute limit.", 8)
                if action == "finish":
                    if len(audio) < 3200 * 4:
                        self.notify("Recording was too short. Hold the key a little longer.")
                    else:
                        job = dict(audio=audio, prefs=copy.deepcopy(self.prefs), target=self.target, cancel=threading.Event())
                        self.pending.append(job); self.work.put(job)
            except Exception as error: self.notify(str(error), 8)

    def cancel(self):
        if self.gesture.mode != "none":
            self.action(self.gesture.cancel())
        else:
            queued = [j for j in self.pending if j is not self.current and not j["cancel"].is_set()]
            if queued: queued[-1]["cancel"].set()
            elif self.current: self.current["cancel"].set()

    def _worker(self):
        while True:
            job = self.work.get()
            if job is None: return
            cancel, prefs = job["cancel"], job["prefs"]
            self.events.put(("job_start", job))
            try:
                raw = self.speech.call(dict(model=str(Path(prefs.modelDirectory) / prefs.speechModel),
                    audio=base64.b64encode(job["audio"]).decode("ascii")), cancel, 600)
                if not raw: raise RuntimeError("No speech was detected")
                text, status, notice = raw, "Off", ""
                if prefs.cleanup:
                    self.events.put(("stage", "Formatting"))
                    try:
                        text = self.cleanup.call(dict(model=str(Path(prefs.modelDirectory) / CATALOG[3].filename),
                            text=raw, styling=prefs.styling, structure=prefs.structure, context=prefs.context), cancel, 30)
                        if not text: raise RuntimeError("S1-mini returned no text")
                        status = "Completed"
                    except Cancelled: raise
                    except Exception as error:
                        text, status = raw, "Failed; original retained"
                        notice = "Formatting failed; original retained. " + str(error)
                if cancel.is_set(): raise Cancelled()
                text = replace_text(text, prefs.replacements)
                entry = history_entry(raw, text, prefs, len(job["audio"]) / (16000 * 4), status)
                unsaved = None
                try: self.history.append(entry)
                except Exception as error:
                    unsaved = entry; notice += " Could not save history: " + str(error)
                self.events.put(("stage", "Pasting"))
                try:
                    if not win.paste(text, job["target"], cancel):
                        notice += " Transcript copied to clipboard; paste it manually if needed."
                except Exception as error:
                    # Publish the result even when BOTH history and clipboard are unavailable.
                    notice += " Could not paste: " + str(error)
                self.events.put(("result", (text, unsaved, notice)))
            except Cancelled: pass
            except Exception as error: self.events.put(("notice", str(error)))
            finally: self.events.put(("job_done", job))

    def tick(self):
        if self.closing: return
        try:
            for _ in range(200):
                try: event, value = self.events.get_nowait()
                except queue.Empty: break
                if event == "press":
                    now, target = value
                    action = self.gesture.press(now)
                    if action in ("start", "restart"): self.target = target
                    self.action(action)
                elif event == "release": self.action(self.gesture.release(value))
                elif event == "chord":
                    if self.gesture.mode in ("held", "waiting"): self.action(self.gesture.cancel())
                elif event == "cancel": self.cancel()
                elif event == "select_key":
                    if value == 0x14: self.notify("Caps Lock cannot be used for hold-to-dictate"); continue
                    if value != 0x1B:
                        self.prefs.key = self.keyboard.key = value; self.save()
                    self.key_select = self.keyboard.capture_key = False
                    self.key_button.configure(text="Dictation key: " + win.key_name(self.prefs.key))
                elif event == "settings": self.show()
                elif event == "history": self.show(True)
                elif event == "paste_last":
                    if self.last:
                        threading.Thread(target=win.paste, args=(self.last, self.paste_last_target, threading.Event()), daemon=True).start()
                elif event == "quit": self.quit(); return
                elif event == "notice": self.notify(value, 10)
                elif event == "job_start": self.current = value; self.stage = "Transcribing"
                elif event == "job_done":
                    self.pending = [j for j in self.pending if j is not value]
                    if self.current is value: self.current = None; self.stage = ""
                elif event == "stage": self.stage = value
                elif event == "result":
                    self.last, self.unsaved, notice = value
                    if notice: self.notify(notice, 10)
                    self.refresh_history()
                elif event == "progress": self.download_progress.set(value)
                elif event == "download_done": self.downloading = False; self.notify(value, 8)
            now = time.monotonic()
            # Opening the tray menu focuses the taskbar, so remember the app the user was in.
            self.paste_last_target = win.paste_target() or self.paste_last_target
            self.action(self.gesture.tick(now))
            if self.gesture.mode != "none" and (self.recorder.full or self.recorder.error):
                self.gesture.mode = "none"; self.action("finish")
            if self.gesture.mode == "none" and now >= self.next_devices:
                self.next_devices = now + 5
                try: self.refresh_devices()
                except Exception as error: self.notify(str(error))
            self.keyboard.can_cancel = self.gesture.mode != "none" or bool(self.pending)
            recording = self.gesture.mode == "locked" or (self.gesture.mode == "held" and now - self.gesture.pressed >= .22)
            label = "Recording hands-free" if self.gesture.mode == "locked" else "Listening"
            text = label if recording else self.stage or (self.notice if now < self.notice_until else None)
            self.overlay.draw(text, self.recorder.level, self.prefs.orbPosition)
            if text: self.status.set(text)
            else: self.status.set("Ready · " + win.key_name(self.prefs.key))
        except Exception as error:
            self.notify(str(error), 8)
        self.root.after(40, self.tick)

    def quit(self):
        self.closing = True
        self.keyboard.stop(); self.download_cancel.set()
        for job in self.pending: job["cancel"].set()
        try: self.recorder.stop()
        except Exception: pass
        self.work.put(None)
        self.worker_thread.join(timeout=2)
        self.speech.close(); self.cleanup.close()
        self.tray.stop(); self.overlay.window.destroy(); self.root.destroy()
