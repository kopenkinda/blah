# Blah

A new macOS 27 dictation app written in Swift 6 with SwiftUI and AppKit.
Hex is the reference for the gestures and model choices. Blah runs independently
and contains none of Hex's application, service, or Rust helper code.

## Run

```sh
./scripts/run.sh
```

This builds the app, replaces your previous local Blah build, installs it at
`~/Applications/Blah.app`, and launches it. It does not replace Hex.

Enable Microphone, Input Monitoring, and Accessibility in Blah's settings.
Quit Hex when you are ready to switch. Blah pauses its key listener while Hex
is running so a gesture cannot start both apps.

The default key is Globe / Fn. Set "Press Globe key to" to "Do Nothing" in
macOS Keyboard settings. You can instead select a right-side modifier or a
function key in Blah.

- Hold the key, speak, and release to transcribe and paste.
- Double-tap within 300 ms to record hands-free. Tap again to finish.
- Escape cancels the recording, or the newest unfinished transcript.

A press becomes a hold after 220 ms. A single short tap is discarded.
The microphone opens on the initial press and closes after recording.
The floating particle orb fits within 36 × 36 points, inside a compact native
glass pill, and never takes keyboard focus. Its pink and indigo particles ripple with your voice
and contract rhythmically while processing. An amber orb
signals a notice. For now, its full text appears beneath the orb for eight
seconds and stays in settings. "No speech was detected" disappears from the
overlay after three seconds. Clipboard-only completion and cancellation
do not show warnings. Completed transcripts are saved to local history,
and the last transcript is restored when Blah starts.
Choose one of nine positions in settings. Selecting a position previews it on
screen for three seconds. The position is saved and defaults to bottom center.

## Models

Blah reads the existing model files from:

```text
~/Library/Application Support/voice-control/models/
  parakeet-unified-en-0.6b-Q8_0.gguf
  s1-mini-q4_k_m.gguf
```

Choose another folder in settings if you move them. Both models process English
locally. Blah does not modify Hex's settings or model files.

S1-mini cleanup starts enabled with semi-casual styling, lists, and general
context, matching the inspected Hex configuration. You can disable it or change
those three options. Cleanup failures, timeouts, or transcripts above the
model's 1,000-token input limit preserve the original transcript.

Audio exists only in memory. The most recent transcript remains available to
copy after restarting. If the original app is no longer in front, Blah copies
the result instead of pasting into another app. After an automatic paste, it
restores the previous clipboard unless the user has copied something else.

## Transcript history

Every completed dictation is saved as one JSON object per line in this UTF-8 file:

```text
~/Library/Application Support/Blah/history.jsonl
```

Use **Open history** or **Show in Finder** in settings, or **Open transcript
history…** in the menu bar. Each entry contains `id`, `createdAt` as an ISO 8601
timestamp, `rawText`, and final `text`. Edit entries or delete whole lines with
any text editor. Text line breaks are escaped inside each JSON record.

There is no time-based expiry. Blah keeps the newest 2,000 entries, removing
the oldest when a new transcript exceeds that limit. Below the limit, new
entries are appended. At the limit, the file is replaced atomically. Blah
reads the current file before each save, so it does not restore deleted entries
from memory. If you delete the file, the next dictation creates a fresh one.
Save edits before dictating again so your editor does not overwrite a new entry.

The menu bar's **Copy last transcript** restores the latest entry after a
restart and re-reads history when used. Settings can also copy the original
text. A malformed line is reported by line number; Blah will not overwrite
that file. If saving fails, the new transcript remains available in memory
to copy, and normal paste/clipboard delivery continues.

History is saved whether automatic pasting succeeds or falls back to the
clipboard. Recordings cancelled before completion and recordings without a
transcript are not added. Audio is never written to disk.

Existing `Transcripts.txt` entries are imported once, preserving their timestamps.
The original text log is retained as a backup. Those old entries only contain
final text, so the imported `rawText` matches `text`.

## Develop

`Artwork/Blah.icon` is the editable Icon Composer app icon. Two SVG layers form
a talking face and sound waves, with light, dark, and clear-glass appearances.
Both the command-line build and Xcode compile it into the app's asset catalog.

Requirements: Apple silicon, macOS 27, Swift 6.4, the macOS 27 SDK, Xcode 27's
SwiftUI compiler plugins, and CMake for a fresh native-runtime build.

```sh
./scripts/build.sh                 # Build without installing or launching
CONFIGURATION=Release ./scripts/run.sh
open Blah.xcodeproj                # Select the Blah scheme
```

Xcode may require you to accept its license on first launch. The command-line
build also works with the installed Command Line Tools and Xcode's platform
plugins. Set `BLAH_XCODE_DIR` if Xcode lives outside `/Applications/Xcode.app`.

Native inference libraries build once and are cached under `.build/runtimes`.
The bootstrap downloads checksum-pinned source archives matching the model
runtimes in the old app. It compiles only C/C++ and Metal; Rust is not required.
On this Mac, the initial build reused the existing compiled libraries.

Signing follows MenuDot's local development setup. The first build creates a
private keychain and self-signed certificate under
`~/Library/Application Support/Blah/Signing`. Command-line and Xcode builds reuse
that certificate, pinning the app's identity to it so privacy permissions can
survive rebuilds. Keep this directory private and intact. The signing script
does not change system certificate trust or your default keychain.

Switching from the original ad-hoc build may require granting permissions once
more. If macOS still shows an enabled entry that Blah cannot use, remove Blah
from that permission list and add `~/Applications/Blah.app` again, then reopen
the app. The installer verifies and replaces the whole bundle at this stable
path, instead of updating files inside a running app.

The app has no test target or test suite.

## Ownership

- `DictationController.swift` owns gesture state, capture cancellation, and the
  ordered queue. A new recording can begin while a previous job is processing.
- `KeyMonitor.swift` owns global keyboard events. Modifier flags are observed
  passively so ordinary keyboard shortcuts still work.
- `AudioRecorder.swift` owns AVAudioEngine and conversion to mono 16 kHz PCM.
- `Inference.swift` owns the warm Parakeet session and optional S1-mini process.
  Only this actor accesses the speech inference session.
- `Sources/Cleanup/main.swift` is a Swift executable wrapping llama.cpp. Its
  separate process keeps the two runtimes' GGML symbols apart, makes a stalled
  cleanup cancellable, and releases cleanup model memory when disabled.
- `TextInsertion.swift` owns paste and clipboard restoration.
- `TranscriptHistory.swift` appends completed transcripts to the editable local history file.
- The remaining Swift files contain preferences, the app entry point, settings,
  and the recording indicator.

There is no cloud provider, HTTP server, command system, transcript database,
updater, or general-purpose plugin layer.
