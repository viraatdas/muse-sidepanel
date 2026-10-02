#!/bin/bash
# Builds "build/Muse Sidepanel.app". Pass --install to also copy it to /Applications, relaunch,
# and turn off Notification Center's trackpad edge swipe so the panel can use it.
set -euo pipefail
cd "$(dirname "$0")/.."

# 3 = Notification Center opens on the edge swipe (macOS default), 0 = off.
set_edge_gesture() {
    defaults write com.apple.AppleMultitouchTrackpad TrackpadTwoFingerFromRightEdgeSwipeGesture -int "$1"
    defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadTwoFingerFromRightEdgeSwipeGesture -int "$1"
    defaults -currentHost write NSGlobalDomain com.apple.trackpad.twoFingerFromRightEdgeSwipeGesture -int "$1"
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
}

if [[ "${1:-}" == "--restore-gesture" ]]; then
    set_edge_gesture 3
    echo "Notification Center's trackpad edge swipe is back on"
    exit 0
fi

APP="build/Muse Sidepanel.app"
# Universal, so a release built on Apple Silicon also runs on Intel Macs. Each slice is built on
# its own and merged with lipo; `swift build --arch a --arch b` goes through Xcode's build
# service instead, which can hang.
SLICES=()
for ARCH in arm64 x86_64; do
    swift build -c release --triple "$ARCH-apple-macosx"
    SLICES+=("$(swift build -c release --triple "$ARCH-apple-macosx" --show-bin-path)/MuseSidepanel")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/MuseSidepanel"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# A real identity keeps macOS permissions (microphone, login item) stable across rebuilds.
IDENTITIES="$(security find-identity -v -p codesigning)"
IDENTITY="${SIGN_IDENTITY:-$(awk -F'"' '/Developer ID Application/ {print $2; exit}' <<<"$IDENTITIES")}"
IDENTITY="${IDENTITY:-$(awk -F'"' '/Apple Development/ {print $2; exit}' <<<"$IDENTITIES")}"
if [[ -n "$IDENTITY" ]]; then
    # Hardened runtime and a secure timestamp are what notarization requires.
    codesign --force --options runtime --timestamp \
        --entitlements Resources/MuseSidepanel.entitlements --sign "$IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built $APP (signed with: ${IDENTITY:-ad hoc})"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/Muse Sidepanel.app"

    # Hand the "two fingers in from the trackpad's right edge" swipe to the panel by switching
    # off Notification Center's claim on it. Undo: scripts/build-app.sh --restore-gesture
    set_edge_gesture 0
    pkill -x MuseSidepanel && sleep 1 || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open -g "$DEST"
    echo "Installed and launched $DEST"
fi
