from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path
import threading
import urllib.request


@dataclass(frozen=True)
class Model:
    name: str
    filename: str
    repository: str
    revision: str
    size: int
    sha256: str

    @property
    def url(self) -> str:
        return f"https://huggingface.co/{self.repository}/resolve/{self.revision}/{self.filename}"


CATALOG = [
    Model("Parakeet Unified English", "parakeet-unified-en-0.6b-Q8_0.gguf", "handy-computer/parakeet-unified-en-0.6b-gguf", "7e948f21b7bdbac698d3318db9d350f1096f3b6c", 731357568, "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795"),
    Model("Parakeet v2 (English)", "parakeet-tdt-0.6b-v2-Q8_0.gguf", "handy-computer/parakeet-tdt-0.6b-v2-gguf", "07cee0616125a08ef619729bb47f40ef747e4bc4", 729574912, "f0d0e99cebb6d3b83f1f7069b82b5d3c2e39a54545b0da039cb4bafd9c4e5caa"),
    Model("Parakeet v3 (25 European languages)", "parakeet-tdt-0.6b-v3-Q8_0.gguf", "handy-computer/parakeet-tdt-0.6b-v3-gguf", "85ac09ea12fc4b1112fa76810059364bc6adc9de", 739508576, "5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7"),
    Model("S1-mini (English formatting, Superwhisper)", "s1-mini-q4_k_m.gguf", "superwhisper/s1-mini-GGUF", "ee2c0f56e56345f475749a44ff2893e21c3cb292", 484219808, "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634"),
]


class Cancelled(Exception):
    pass


def download(model: Model, directory: Path, cancel: threading.Event, progress=lambda value: None,
             opener=urllib.request.urlopen) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / model.filename
    if destination.exists():
        raise FileExistsError(f"{model.filename} already exists; move it aside before downloading again.")
    # Exclusive staging file prevents two running downloads from sharing partial data.
    import tempfile
    import os
    fd, temporary = tempfile.mkstemp(prefix=".download-", dir=directory)
    try:
        digest = hashlib.sha256()
        size = 0
        with os.fdopen(fd, "wb") as output, opener(model.url, timeout=30) as response:
            if response.status != 200:
                raise ValueError("The download server did not provide the model")
            while True:
                if cancel.is_set():
                    raise Cancelled()
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > model.size:
                    raise ValueError("Model download exceeds its expected size")
                output.write(chunk)
                digest.update(chunk)
                progress(size / model.size)
            output.flush()
            os.fsync(output.fileno())
        if cancel.is_set():
            raise Cancelled()
        if size != model.size or digest.hexdigest() != model.sha256:
            raise ValueError("Model failed size/SHA-256 verification")
        # Windows rename fails if the destination was created in the meantime.
        if destination.exists():
            raise FileExistsError(str(destination))
        os.rename(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
