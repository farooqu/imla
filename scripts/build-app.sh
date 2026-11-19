#!/bin/bash
# Builds Imla.app, signs it, and installs it to ~/Applications.
# A stable signing identity keeps macOS Microphone and Accessibility grants
# across rebuilds; ad-hoc signatures lose them every time.
set -euo pipefail
cd "$(dirname "$0")/.."

# Command Line Tools build SwiftPM without accepting the full Xcode license.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
# By SHA-1, sorted: names repeat in the keychain and find-identity's order isn't stable.
IDENTITY="${IMLA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2}' | sort | head -1)}"
DEST="${IMLA_INSTALL_DIR:-$HOME/Applications}"

./scripts/build-runtime.sh
swift build -c release --build-system native
BIN="$(swift build -c release --build-system native --show-bin-path)/Imla"

APP="build/Imla.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Imla"
# The NeMo-Speech.cpp runtime and libllama; the models live in shared caches.
cp -a .runtime/lib/*.dylib "$APP/Contents/Frameworks/"
mkdir -p "$APP/Contents/Resources/NeMo-Speech" "$APP/Contents/Resources/llama.cpp"
cp .runtime/lib/LICENSE .runtime/lib/NOTICE .runtime/lib/THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/NeMo-Speech/"
cp .runtime/lib/LICENSE-llama.cpp "$APP/Contents/Resources/llama.cpp/LICENSE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

for lib in "$APP"/Contents/Frameworks/*.dylib; do
    [ -L "$lib" ] || codesign --force --sign "${IDENTITY:--}" --options runtime "$lib"
done
codesign --force --sign "${IDENTITY:--}" --options runtime --entitlements Resources/Imla.entitlements "$APP"
codesign --verify --strict "$APP"

mkdir -p "$DEST"
pkill -x Imla 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST/Imla.app"
cp -R "$APP" "$DEST/"
echo "Installed $DEST/Imla.app (signed with: ${IDENTITY:-ad-hoc})"
