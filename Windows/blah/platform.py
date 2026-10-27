"""Windows keyboard, clipboard and startup integration. All pointers are 64-bit safe."""
from __future__ import annotations

import ctypes as C
from ctypes import wintypes as W
import os
import threading
import time
import winreg

user32 = C.WinDLL("user32", use_last_error=True)
kernel32 = C.WinDLL("kernel32", use_last_error=True)
LRESULT = C.c_ssize_t
ULONG_PTR = C.c_size_t
HOOKPROC = C.WINFUNCTYPE(LRESULT, C.c_int, W.WPARAM, W.LPARAM)


class KBD(C.Structure):
    _fields_ = [("vkCode", W.DWORD), ("scanCode", W.DWORD), ("flags", W.DWORD),
                ("time", W.DWORD), ("extra", ULONG_PTR)]


class KEYBDINPUT(C.Structure):
    _fields_ = [("vk", W.WORD), ("scan", W.WORD), ("flags", W.DWORD),
                ("time", W.DWORD), ("extra", ULONG_PTR)]


class MOUSEINPUT(C.Structure):
    _fields_ = [("dx", W.LONG), ("dy", W.LONG), ("data", W.DWORD),
                ("flags", W.DWORD), ("time", W.DWORD), ("extra", ULONG_PTR)]


class INPUTUNION(C.Union):
    _fields_ = [("keyboard", KEYBDINPUT), ("mouse", MOUSEINPUT)]


class INPUT(C.Structure):
    _fields_ = [("type", W.DWORD), ("value", INPUTUNION)]


user32.SetWindowsHookExW.argtypes = [C.c_int, HOOKPROC, W.HINSTANCE, W.DWORD]
user32.SetWindowsHookExW.restype = W.HANDLE
user32.CallNextHookEx.argtypes = [W.HANDLE, C.c_int, W.WPARAM, W.LPARAM]
user32.CallNextHookEx.restype = LRESULT
user32.UnhookWindowsHookEx.argtypes = [W.HANDLE]
user32.GetForegroundWindow.restype = W.HWND
user32.SetForegroundWindow.argtypes = [W.HWND]
user32.IsWindow.argtypes = [W.HWND]
user32.SendInput.argtypes = [W.UINT, C.POINTER(INPUT), C.c_int]
user32.GetAsyncKeyState.argtypes = [C.c_int]
user32.GetAsyncKeyState.restype = C.c_short
user32.GetKeyNameTextW.argtypes = [W.LONG, W.LPWSTR, C.c_int]
user32.MapVirtualKeyW.argtypes = [W.UINT, W.UINT]
kernel32.GetModuleHandleW.argtypes = [W.LPCWSTR]
kernel32.GetModuleHandleW.restype = W.HMODULE
kernel32.GlobalAlloc.argtypes = [W.UINT, C.c_size_t]
kernel32.GlobalAlloc.restype = W.HGLOBAL
kernel32.GlobalLock.argtypes = [W.HGLOBAL]
kernel32.GlobalLock.restype = C.c_void_p
kernel32.GlobalUnlock.argtypes = [W.HGLOBAL]
kernel32.GlobalFree.argtypes = [W.HGLOBAL]
user32.SetClipboardData.argtypes = [W.UINT, W.HANDLE]
user32.SetClipboardData.restype = W.HANDLE
user32.OpenClipboard.argtypes = [W.HWND]
user32.CreateWindowExW.argtypes = [W.DWORD, W.LPCWSTR, W.LPCWSTR, W.DWORD,
    C.c_int, C.c_int, C.c_int, C.c_int, W.HWND, W.HMENU, W.HINSTANCE, C.c_void_p]
user32.CreateWindowExW.restype = W.HWND
user32.DestroyWindow.argtypes = [W.HWND]


user32.GetWindowThreadProcessId.argtypes = [W.HWND, C.POINTER(W.DWORD)]
user32.GetWindowThreadProcessId.restype = W.DWORD
user32.GetClassNameW.argtypes = [W.HWND, W.LPWSTR, C.c_int]
SHELL_CLASSES = {"Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow",
                 "TopLevelWindowForOverflowXamlIsland", "Progman", "WorkerW"}


def paste_target() -> int | None:
    """Foreground window of another app, or None for Blah's own windows and the taskbar/tray."""
    hwnd = user32.GetForegroundWindow()
    if not hwnd:
        return None
    pid = W.DWORD()
    user32.GetWindowThreadProcessId(hwnd, C.byref(pid))
    if pid.value == os.getpid():
        return None
    name = C.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, name, len(name))
    return None if name.value in SHELL_CLASSES else hwnd


def key_name(key: int) -> str:
    known = {0xA0: "Left Shift", 0xA1: "Right Shift", 0xA2: "Left Ctrl", 0xA3: "Right Ctrl",
             0xA4: "Left Alt", 0xA5: "Right Alt", 0x5B: "Left Windows", 0x5C: "Right Windows"}
    if key in known:
        return known[key]
    scan = user32.MapVirtualKeyW(key, 0) << 16
    if key in (0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E):
        scan |= 1 << 24
    buffer = C.create_unicode_buffer(128)
    user32.GetKeyNameTextW(scan, buffer, len(buffer))
    return buffer.value or f"Key {key}"


def send_keys(keys: list[tuple[int, bool]]) -> bool:
    items = (INPUT * len(keys))()
    for item, (key, up) in zip(items, keys):
        item.type = 1
        extended = 1 if key in (0xA3, 0xA5, 0x5B, 0x5C, 0x2D, 0x2E, 0x25, 0x26, 0x27, 0x28) else 0
        item.value.keyboard = KEYBDINPUT(key, 0, extended | (2 if up else 0), 0, 0)
    return user32.SendInput(len(items), items, C.sizeof(INPUT)) == len(items)


MODIFIERS = (0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C)


class Keyboard:
    def __init__(self, events, key=0xA3):
        self.events, self.key = events, key
        self.pressed = set()
        self.active = False
        self.chord = False
        self.capture_key = False
        self.can_cancel = False
        self.thread_id = None
        self.ready = threading.Event()
        self.error = None
        self.callback = HOOKPROC(self._hook)

    def start(self):
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()
        if not self.ready.wait(5) or self.error:
            raise RuntimeError(self.error or "Keyboard monitor could not start")

    def _run(self):
        self.thread_id = kernel32.GetCurrentThreadId()
        hook = user32.SetWindowsHookExW(13, self.callback, kernel32.GetModuleHandleW(None), 0)
        if not hook:
            self.error = "Windows rejected the keyboard monitor"
            self.ready.set()
            return
        self.ready.set()
        message = W.MSG()
        try:
            while user32.GetMessageW(C.byref(message), None, 0, 0) > 0:
                user32.TranslateMessage(C.byref(message))
                user32.DispatchMessageW(C.byref(message))
        finally:
            user32.UnhookWindowsHookEx(hook)
            if self.active and self.chord:
                send_keys([(self.key, True)])

    def _hook(self, code, message, pointer):
        if code < 0:
            return user32.CallNextHookEx(None, code, message, pointer)
        data = C.cast(pointer, C.POINTER(KBD)).contents
        if data.flags & 0x10:  # Ignore our injected paste and chord replay events.
            return user32.CallNextHookEx(None, code, message, pointer)
        key = data.vkCode
        down = message in (0x100, 0x104)
        repeated = key in self.pressed
        if down:
            self.pressed.add(key)
        else:
            self.pressed.discard(key)
        if self.capture_key:
            if down and not repeated:
                self.events.put(("select_key", key))
            return 1
        if key == 0x1B and self.can_cancel:
            if down and not repeated:
                self.events.put(("cancel", None))
            return 1
        if key == self.key:
            if down and not repeated:
                self.chord = any(user32.GetAsyncKeyState(k) & 0x8000 for k in MODIFIERS if k != key)
                self.active = not self.chord
                if self.active:
                    self.events.put(("press", (time.monotonic(), user32.GetForegroundWindow())))
            elif not down and self.active:
                self.events.put(("release", time.monotonic()))
                swallow = not self.chord
                self.active = False
                return 1 if swallow else user32.CallNextHookEx(None, code, message, pointer)
            if self.active and not self.chord:
                return 1
        elif down and not repeated and self.active and not self.chord:
            self.chord = True
            send_keys([(self.key, False)])
            self.events.put(("chord", None))
        return user32.CallNextHookEx(None, code, message, pointer)

    def stop(self):
        if self.thread_id:
            user32.PostThreadMessageW(self.thread_id, 0x12, 0, 0)
            self.thread.join(timeout=2)


def clipboard(text: str):
    encoded = (text + "\0").encode("utf-16-le")
    # EmptyClipboard must have a real owner before SetClipboardData.
    # A message-only STATIC window is invisible and belongs to this calling thread.
    owner = user32.CreateWindowExW(0, "STATIC", "Blah clipboard", 0, 0, 0, 0, 0, W.HWND(-3), None, None, None)
    if not owner:
        raise C.WinError(C.get_last_error())
    for _ in range(10):
        if user32.OpenClipboard(owner):
            break
        time.sleep(0.02)
    else:
        user32.DestroyWindow(owner)
        raise RuntimeError("Clipboard is busy. The transcript is available in History.")
    handle = None
    try:
        if not user32.EmptyClipboard():
            raise C.WinError(C.get_last_error())
        handle = kernel32.GlobalAlloc(0x2, len(encoded))
        if not handle:
            raise MemoryError("Could not allocate clipboard data")
        pointer = kernel32.GlobalLock(handle)
        if not pointer:
            raise C.WinError(C.get_last_error())
        C.memmove(pointer, encoded, len(encoded))
        kernel32.GlobalUnlock(handle)
        if not user32.SetClipboardData(13, handle):
            raise C.WinError(C.get_last_error())
        handle = None  # Clipboard now owns the memory.
    finally:
        if handle:
            kernel32.GlobalFree(handle)
        user32.CloseClipboard()
        user32.DestroyWindow(owner)


def paste(text: str, target: int | None, cancel: threading.Event) -> bool:
    if cancel.is_set():
        return False
    clipboard(text)
    if not target or not user32.IsWindow(target):
        return False
    user32.SetForegroundWindow(target)
    deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        if cancel.is_set():
            return False
        if user32.GetForegroundWindow() == target and not any(user32.GetAsyncKeyState(k) & 0x8000 for k in MODIFIERS):
            return send_keys([(0x11, False), (0x56, False), (0x56, True), (0x11, True)])
        time.sleep(0.025)
    return False


RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"


def startup_enabled() -> bool:
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            winreg.QueryValueEx(key, "Blah")
        return True
    except FileNotFoundError:
        return False


def set_startup(enabled: bool, command: str):
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
        if enabled:
            winreg.SetValueEx(key, "Blah", 0, winreg.REG_SZ, command)
        else:
            try:
                winreg.DeleteValue(key, "Blah")
            except FileNotFoundError:
                pass
