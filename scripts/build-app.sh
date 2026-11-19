#!/bin/bash
# Builds Imla.app, signs it, and installs it to ~/Applications.
#
# Environment:
#   IMLA_SIGN_IDENTITY  codesign identity. Default: "Imla Release" if it's in the
#                       keychain, else an Apple Development certificate, else ad hoc.
#                       A stable identity keeps macOS Microphone and Accessibility
#                       grants across builds; ad hoc signatures lose them every time.
#   IMLA_VERSION        release version, such as 1.2.3. Release builds also get the
#                       update feed; without it the app never updates itself.
#   IMLA_BUILD          build number Sparkle compares; required with IMLA_VERSION.
#   IMLA_INSTALL_DIR    where to install. Default ~/Applications; "none" skips it.
set -euo pipefail
cd "$(dirname "$0")/.."

# Command Line Tools build SwiftPM without accepting the full Xcode license.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
if [ -z "${IMLA_SIGN_IDENTITY:-}" ]; then
    if security find-identity -p codesigning | grep -q '"Imla Release"'; then
        IMLA_SIGN_IDENTITY="Imla Release"
    else
        # By SHA-1, sorted: names repeat in the keychain and find-identity's order isn't stable.
        IMLA_SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2}' | sort | head -1)"
    fi
fi
IDENTITY="${IMLA_SIGN_IDENTITY:--}"
DEST="${IMLA_INSTALL_DIR:-$HOME/Applications}"
FEED_URL="https://github.com/farooqu/imla/releases/latest/download/appcast.xml"

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
# Sparkle, for updates. Its XPC services are only for sandboxed apps.
cp -a .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP/Contents/Frameworks/"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
# Drop rpaths into this checkout so the app loads only the libraries it carries.
for file in "$APP/Contents/MacOS/Imla" "$APP"/Contents/Frameworks/*.dylib; do
    [ -L "$file" ] && continue
    for path in $(otool -l "$file" | awk '/cmd LC_RPATH/ {getline; getline; print $2}'); do
        case "$path" in "$PWD"/*) install_name_tool -delete_rpath "$path" "$file" ;; esac
    done
    case "$file" in *.dylib) install_name_tool -add_rpath @loader_path "$file" 2>/dev/null || true ;; esac
done
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

PLIST="$APP/Contents/Info.plist"
if [ -n "${IMLA_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $IMLA_VERSION" \
        -c "Set :CFBundleVersion ${IMLA_BUILD:?IMLA_BUILD is required with IMLA_VERSION}" \
        -c "Add :SUFeedURL string $FEED_URL" "$PLIST"
fi

# Inside out: nested code first, then the bundles that contain it.
sign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
for lib in "$APP"/Contents/Frameworks/*.dylib; do
    [ -L "$lib" ] || sign "$lib"
done
sign --entitlements Resources/Imla.entitlements "$APP"
codesign --verify --strict --deep "$APP"

if [ "$DEST" = none ]; then
    echo "Built $APP $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST") (signed with: $IDENTITY)"
    exit 0
fi
mkdir -p "$DEST"
pkill -x Imla 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST/Imla.app"
cp -R "$APP" "$DEST/"
echo "Installed $DEST/Imla.app (signed with: $IDENTITY)"
