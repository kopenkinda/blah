"""Collect redistributable dependency notices beside the portable executable."""
from importlib.metadata import distribution
from pathlib import Path
import shutil
import sys

root = Path(__file__).resolve().parents[1]
output = root / "dist/Blah/THIRD_PARTY_LICENSES"
output.mkdir(parents=True, exist_ok=True)
for name in ("sounddevice", "pystray", "Pillow", "cffi", "pycparser", "six", "pyinstaller"):
    dist = distribution(name)
    for relative in dist.files or []:
        if any(word in Path(relative).name.lower() for word in ("license", "copying", "notice")):
            source = Path(dist.locate_file(relative))
            if source.is_file():
                target = output / name / source.name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
base = Path(sys.base_prefix)
shutil.copy2(base / "LICENSE.txt", output / "Python-LICENSE.txt")
for source in (base / "tcl").rglob("license.terms"):
    target = output / "TclTk" / source.relative_to(base / "tcl")
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
# PortAudio's binary wheel includes third-party notices in this README.
dist = distribution("sounddevice")
for relative in dist.files or []:
    if "portaudio-binaries" in str(relative) and Path(relative).suffix.lower() in (".md", ".txt"):
        source = Path(dist.locate_file(relative))
        target = output / "PortAudio" / source.name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
print("Collected dependency licenses in", output)
for source in (root / ".build/windows/runtimes").glob("COPYING*"):
    shutil.copy2(source, output / source.name)
for source in (root / "Windows/licenses").glob("*.txt"):
    shutil.copy2(source, output / source.name)
