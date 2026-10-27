# Blah for Windows

Blah runs local dictation on Windows 10/11 x64. It uses the same Parakeet GGUF
models and optional Superwhisper S1-mini formatting model as the macOS version.
Audio and transcripts are never sent to a speech service. Network access is only
needed to download models or build dependencies.

## Run the portable app

Extract **the entire** `Blah-Windows-x64.zip`, then run `Blah/Blah.exe`. Keep
`_internal` beside the exe; this is a portable application folder, not a single
standalone executable. Python and a GPU are not required. The build uses the CPU
backend and an x86-64 baseline, so it can be slower than the macOS Metal backend.

1. Open **Models** and download a speech model. Choose Parakeet v3 for its 25
   supported European languages; Unified and v2 are English. Download S1-mini
   for optional English formatting, or turn formatting off in General.
2. Enable **Microphone access** and **Let desktop apps access your microphone**
   in Windows Settings if capture is denied. Select microphone priority in Blah.
3. Focus the application where you want text, hold **Right Ctrl**, speak, and
   release. Choose another key in General if preferred. Globe/Fn is generally
   handled by keyboard firmware and is not a portable Windows shortcut.

Double-tap the key to record hands-free; tap again to finish. Escape cancels the
capture, newest queued dictation, or current inference job. A single short tap is
discarded. Key repeat does not start extra recordings. Combinations with the
dictation key are passed through; using a combination during a held recording
discards that capture. Caps Lock is excluded from key selection.

Blah stays in the notification area when Settings closes. Its tray menu offers
Settings, paste last transcript, Transcript History and Quit. General includes
formatting style/structure/context, nine overlay positions, independent start/stop
sounds and volume, and launch at login. Windows uses synthesized versions of the
four named sound cues, rather than macOS system sound files. Microphones use WASAPI
shared mode with Windows sample-rate conversion to 16 kHz mono float audio.
Disconnected devices stay in the preference order. Devices are identified by
their full Windows names and duplicate ordinal; renaming a device, or reconnecting
identically named microphones in a different order, can require reordering them.

The overlay is a native, nonactivating particle indicator. It uses the primary
display; monitor-specific placement and the original SwiftUI animation are not
ported pixel-for-pixel. Formatting retains the original 1,000-token
input limit, 1,200-token output limit and 30-second deadline.

Formatting failures retain the original transcript, then apply replacements.
Replacements run in order, with literal replacement text, optional match case and
Unicode whole-word boundaries. History holds the latest 2,000 entries, including
raw text, final text, model names, duration and formatting outcome. Search and
copy entries from Transcript History. Audio is held in memory, never saved.

Pasting uses the application window captured when recording started. If Windows
refuses to focus or inject input (for example into an elevated app), the transcript
stays on the clipboard and in History. Paste manually with Ctrl+V. If the clipboard
is unavailable, retrieve the transcript from History. Prefer running both apps
with their normal permissions.

## Files and existing models

Settings and history live in:

```text
%LOCALAPPDATA%\Blah\preferences.json
%LOCALAPPDATA%\Blah\history.jsonl
%LOCALAPPDATA%\Blah\models\
```

Choose any model folder in Models, including one copied from a Mac or Hex.
Downloads retain the original pinned revisions, byte counts and SHA-256 hashes.
Partial or unverified downloads are not installed, and existing model files are
not overwritten. Model weights are not bundled in the portable archive.

The JSONL history has the same field names as macOS and accepts ISO-8601 dates;
it can be copied between platforms. Preferences are separate because Windows keys
and microphone identifiers differ. Manual history edits are reread before each
append. Invalid history blocks further writes instead of replacing damaged data;
the current transcript remains copyable in the app. The macOS legacy
`Transcripts.txt` importer remains in the Mac app; Windows accepts JSONL only.

## Build

Install Python **3.13 x64** and Visual Studio 2022 Build Tools with **Desktop
development with C++**, including its Windows SDK. Then run from the repository:

```powershell
./scripts/build-windows.ps1
```

The script creates an isolated `.build/venv`, installs pinned direct dependencies,
runs tests, verifies and builds the same native source archives used on macOS,
packages Python/Tk/PortAudio and both native engines, runs a packaged self-test,
and writes `dist/Blah-Windows-x64.zip`. The native libraries are statically linked
into separate DLLs; each engine runs in its own restartable worker process so the
two GGML versions do not share global state. Cancellation kills the active worker;
the next request reloads the model. Normal requests reuse loaded models.

A MinGW-w64 toolchain can be supplied without installing Visual Studio:

```powershell
./scripts/build-windows.ps1 -Generator Ninja -CC gcc -CXX g++
```

Have `gcc`/`g++` on PATH. The helper bundles `libwinpthread-1.dll` when required.
The local release was built with w64devkit 2.4.0. GitHub Actions builds with MSVC
on Windows Server 2022 and uploads the portable archive and self-test report.
Additional CI jobs run the portable core tests on Linux and the original Swift
replacement tests on macOS. Full macOS app builds still require macOS/Xcode 27.

To run from source after installing requirements and building the native engines:

```powershell
.build/venv/Scripts/python.exe Windows/main.py
```

## Tests

```powershell
.build/venv/Scripts/python.exe -m unittest discover -s Windows/tests -v
dist/Blah/Blah.exe --self-test --report self-test.json
```

Core tests cover hold/double-tap/cancel timing, Unicode replacements, preferences,
history corruption/retention/external edits, and verified/cancelled model downloads.
Windows integration tests check input structure layout, key names, microphone
priority, missing-model worker errors, cancellation and safe paste fallback.
The packaged self-test loads both DLLs and checks the actual windowed exe's worker
protocol without recording or altering the clipboard.

Opt into real-model integration with the original GGUF files and the public
`samples/jfk.wav` from [whisper.cpp](https://github.com/ggml-org/whisper.cpp):

```powershell
$env:BLAH_TEST_MODELS = 'C:\models'
$env:BLAH_TEST_AUDIO = 'C:\samples\jfk.wav'
.build/venv/Scripts/python.exe -m unittest discover -s Windows/tests -p test_models.py -v
```

This verifies actual Parakeet transcription and two S1-mini requests.
Set `BLAH_TEST_EXE` to the packaged `Blah.exe` to run these requests through the
actual windowed executable's workers instead of Python source workers. Routine CI
does not download 1.2 GB of model weights. Live microphone hot-plug, physical key
timing, multi-monitor placement, and pasting into arbitrary third-party apps
remain manual acceptance checks. The binary is unsigned.

See the repository LICENSE and THIRD_PARTY_NOTICES.md for model and runtime terms.
