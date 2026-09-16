#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
# Stage and verify the whole bundle before replacing the installed app.
app="$HOME/Applications/Blah.app"
mkdir -p "$HOME/Applications"
if [ -e "$app" ]; then
    installed_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")"
    [ "$installed_id" = com.dk.blah ] || { echo 'A different app occupies the install path.' >&2; exit 1; }
fi
staging="$(mktemp -d "$HOME/Applications/.Blah.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto .build/Blah.app "$staging/Blah.app"
codesign --verify --deep --strict "$staging/Blah.app"

# Quit normally so capture and helper cleanup finish before installing.
swift -e '
import AppKit
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.dk.blah")
for app in apps { app.terminate() }
let deadline = Date().addingTimeInterval(5)
while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
if apps.contains(where: { !$0.isTerminated }) {
    fputs("Quit Blah before installing the update.\n", stderr)
    exit(1)
}
'
if [ -d "$app" ]; then mv "$app" "$staging/previous.app"; fi
if ! mv "$staging/Blah.app" "$app"; then
    if [ -d "$staging/previous.app" ]; then mv "$staging/previous.app" "$app"; fi
    exit 1
fi
open "$app"
