#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
./scripts/prepare-runtimes.sh

app="$PWD/.build/Blah.app"
binaries="$PWD/.build/bin"
mkdir -p "$binaries" "$app/Contents/MacOS" "$app/Contents/Resources"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
options=(-swift-version 6 -sdk "$sdk" -target arm64-apple-macosx27.0 -g)
# SwiftUI 27 supplies its State macro with the platform SDK's compiler plugins.
platform_plugins="${BLAH_XCODE_DIR:-/Applications/Xcode.app/Contents/Developer}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
if [ -d "$platform_plugins" ]; then options+=(-plugin-path "$platform_plugins"); fi
if [ "${CONFIGURATION:-Debug}" = Release ]; then options+=(-O); else options+=(-Onone); fi
frameworks=(-lc++ -framework Accelerate -framework Metal -framework MetalKit -framework Foundation)

xcrun swiftc "${options[@]}" -module-name BlahCleanup \
    -import-objc-header .build/runtimes/llama/include/llama.h \
    -I .build/runtimes/llama/include -L .build/runtimes/llama/lib \
    Sources/Cleanup/main.swift -lllama -lggml -lggml-cpu -lggml-metal -lggml-base \
    "${frameworks[@]}" -o "$binaries/BlahCleanup"

xcrun swiftc "${options[@]}" -parse-as-library -module-name Blah \
    -import-objc-header .build/runtimes/transcribe/include/transcribe.h \
    -I .build/runtimes/transcribe/include -L .build/runtimes/transcribe/lib \
    Sources/Blah/*.swift -ltranscribe -lggml -lggml-cpu -lggml-metal -lggml-base \
    "${frameworks[@]}" -o "$binaries/Blah"

cp "$binaries/Blah" "$binaries/BlahCleanup" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
python3 scripts/sign.py "$app"
printf 'Built %s\n' "$app"
