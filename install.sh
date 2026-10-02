#!/bin/bash
# Installs the latest Muse Sidepanel release into /Applications and launches it.
#   curl -fsSL https://raw.githubusercontent.com/viraatdas/muse-sidepanel/main/install.sh | bash
set -euo pipefail

REPO="viraatdas/muse-sidepanel"
DEST="/Applications/Muse Sidepanel.app"

URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | cut -d'"' -f4 || true)"
[[ -n "$URL" ]] || { echo "Could not find a release to download." >&2; exit 1; }

WORK="$(mktemp -d)"
MOUNT="$WORK/mount"
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

echo "Downloading $URL"
curl -fL --progress-bar "$URL" -o "$WORK/MuseSidepanel.dmg"
hdiutil attach "$WORK/MuseSidepanel.dmg" -nobrowse -quiet -mountpoint "$MOUNT"

# Copy first, swap second: a failed download or copy must not cost the existing install.
cp -R "$MOUNT/Muse Sidepanel.app" "$WORK/Muse Sidepanel.app"
pkill -x MuseSidepanel && sleep 1 || true
rm -rf "$DEST"
mv "$WORK/Muse Sidepanel.app" "$DEST"
open -g "$DEST"

echo "Installed $DEST"
echo "Look for the sidebar icon in the menu bar. On first launch it asks whether to use the"
echo "trackpad edge swipe, which replaces Notification Center's swipe."
