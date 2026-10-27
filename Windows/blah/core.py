from __future__ import annotations

import dataclasses
import datetime
import json
import os
from pathlib import Path
import re
import tempfile
import unicodedata
import uuid


def app_directory() -> Path:
    return Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData/Local")) / "Blah"


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".blah-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


@dataclasses.dataclass
class Replacement:
    find: str = ""
    replacement: str = ""
    matchCase: bool = False
    wholeWords: bool = True


def word_character(char: str) -> bool:
    return char == "_" or unicodedata.category(char)[0] in "LMN"


def replace_text(text: str, rules: list[Replacement]) -> str:
    for rule in rules:
        if not rule.find:
            continue
        def substitute(match: re.Match) -> str:
            a, b = match.span()
            if rule.wholeWords and ((a and word_character(text[a - 1])) or
                                    (b < len(text) and word_character(text[b]))):
                return match.group()
            return rule.replacement
        text = re.sub(re.escape(rule.find), substitute, text,
                      flags=0 if rule.matchCase else re.IGNORECASE)
    return text


@dataclasses.dataclass
class Preferences:
    key: int = 0xA3  # Right Ctrl; Fn is normally not exposed by Windows keyboards.
    microphonePriority: list[str] = dataclasses.field(default_factory=list)
    modelDirectory: str = dataclasses.field(default_factory=lambda: str(app_directory() / "models"))
    speechModel: str = "parakeet-unified-en-0.6b-Q8_0.gguf"
    cleanup: bool = True
    styling: str = "semi-casual"
    structure: str = "lists"
    context: str = "general"
    orbPosition: int = 7
    startSound: str = "Off"
    stopSound: str = "Off"
    startSoundVolume: float = 0.3
    stopSoundVolume: float = 0.3
    replacements: list[Replacement] = dataclasses.field(default_factory=list)

    @classmethod
    def load(cls, path: Path) -> Preferences:
        if not path.exists():
            return cls()
        data = json.loads(path.read_text(encoding="utf-8"))
        # Unknown fields from a newer app are ignored; malformed data is never overwritten.
        data = {k: v for k, v in data.items() if k in {f.name for f in dataclasses.fields(cls)}}
        data["replacements"] = [Replacement(**r) for r in data.get("replacements", [])]
        value = cls(**data)
        if not isinstance(value.key, int) or not 1 <= value.key <= 254 or value.key in (0x14, 0x1B):
            raise ValueError("Invalid dictation key in preferences.json")
        if not 0 <= value.orbPosition <= 8:
            raise ValueError("Invalid overlay position")
        return value

    def save(self, path: Path) -> None:
        atomic_write(path, json.dumps(dataclasses.asdict(self), ensure_ascii=False, indent=2))


class History:
    limit = 2000

    def __init__(self, path: Path):
        self.path = path

    def load(self) -> list[dict]:
        if not self.path.exists():
            return []
        entries = []
        for number, line in enumerate(self.path.read_text(encoding="utf-8").splitlines(), 1):
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
                if not isinstance(entry["text"], str) or not isinstance(entry["rawText"], str):
                    raise ValueError("Invalid transcript")
                entries.append(entry)
            except (ValueError, KeyError, TypeError) as error:
                raise ValueError(f"History line {number} is invalid. Fix history.jsonl; it has not been changed.") from error
        return entries

    def append(self, entry: dict) -> None:
        # Read disk on every append so manual deletions are respected.
        entries = (self.load() + [entry])[-self.limit:]
        atomic_write(self.path, "".join(json.dumps(e, ensure_ascii=False) + "\n" for e in entries))


def history_entry(raw: str, text: str, prefs: Preferences, duration: float, status: str) -> dict:
    return dict(id=str(uuid.uuid4()), createdAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                rawText=raw, text=text, speechModel=prefs.speechModel,
                formattingModel="s1-mini-q4_k_m.gguf" if prefs.cleanup else None,
                duration=duration, formattingStatus=status)


class Gesture:
    """Monotonic-clock state machine, independent of keyboard and recording APIs."""
    def __init__(self):
        self.mode = "none"
        self.pressed = 0.0
        self.deadline = 0.0

    def press(self, now: float) -> str | None:
        if self.mode == "locked":
            self.mode = "none"
            return "finish"
        if self.mode == "waiting" and now <= self.deadline:
            self.mode = "locked"
            return "show"
        if self.mode == "waiting":
            self.mode, self.pressed = "held", now
            return "restart"
        if self.mode != "none":
            return None
        self.mode, self.pressed = "held", now
        return "start"

    def release(self, now: float) -> str | None:
        if self.mode != "held":
            return None
        if now - self.pressed >= 0.22:
            self.mode = "none"
            return "finish"
        self.mode, self.deadline = "waiting", now + 0.3
        return None

    def tick(self, now: float) -> str | None:
        if self.mode == "waiting" and now > self.deadline:
            return self.cancel()
        if self.mode == "held" and now - self.pressed >= 0.22:
            return "show"
        return None

    def cancel(self) -> str | None:
        active = self.mode != "none"
        self.mode = "none"
        return "discard" if active else None
