"""Build the same checksum-pinned engines as macOS, using the CPU backend."""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    ("transcribe-cpp-sys", "0.1.3", "278fd6a6da4d9d8d5f2716bd6761a76ea55c129fda6ba57856b80249a8570ed4"),
    ("llama-cpp-sys-2", "0.1.154", "13a9ea2ce0cdc20bcb1870534022e340b391663f8fe09133951e2fe37fbc29cf"),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--generator", default="Visual Studio 17 2022")
    parser.add_argument("--cc")
    parser.add_argument("--cxx")
    parser.add_argument("--parallel", default="4")
    args = parser.parse_args()
    vendor = ROOT / ".build/vendor"
    output = ROOT / ".build/windows/runtimes"
    vendor.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    for name, version, checksum in SOURCES:
        archive = vendor / f"{name}-{version}.crate"
        if not archive.exists():
            staging = archive.with_suffix(".download")
            try:
                urllib.request.urlretrieve(f"https://static.crates.io/crates/{name}/{name}-{version}.crate", staging)
                if hashlib.sha256(staging.read_bytes()).hexdigest() != checksum:
                    raise RuntimeError(f"Source checksum mismatch: {name}")
                staging.replace(archive)
            finally:
                staging.unlink(missing_ok=True)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
            raise RuntimeError(f"Source checksum mismatch: {name}")
        source = vendor / f"{name}-{version}"
        if not source.exists():
            with tarfile.open(archive) as tar:
                tar.extractall(vendor, filter="data")
    for engine in ("speech", "cleanup"):
        build = ROOT / f".build/windows/{engine}"
        command = ["cmake", "-S", str(ROOT / "Windows/native"), "-B", str(build), "-G", args.generator,
                   f"-DBLAH_ENGINE={engine}", f"-DBLAH_VENDOR={vendor.as_posix()}",
                   f"-DBLAH_OUTPUT={output.as_posix()}", "-DCMAKE_BUILD_TYPE=Release",
                   "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"]
        if args.generator.startswith("Visual Studio"):
            command.extend(["-A", "x64"])
        if args.cc: command.append(f"-DCMAKE_C_COMPILER={args.cc}")
        if args.cxx: command.append(f"-DCMAKE_CXX_COMPILER={args.cxx}")
        subprocess.run(command, check=True)
        subprocess.run(["cmake", "--build", str(build), "--config", "Release", "--target", f"blah_{engine}",
                        "--parallel", args.parallel], check=True)
    # MinGW's threading runtime is required by libstdc++ on some toolchains.
    if args.cc:
        compiler_dir = Path(shutil.which(args.cc) or args.cc).resolve().parent
        for dll in ("libwinpthread-1.dll",):
            if (compiler_dir / dll).exists(): shutil.copy2(compiler_dir / dll, output)
        # Keep the toolchain's redistributable runtime notice with MinGW artifacts.
        for notice in compiler_dir.parent.glob("COPYING*runtime*"):
            shutil.copy2(notice, output / notice.name)


if __name__ == "__main__":
    main()
