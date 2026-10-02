# Muse Sidepanel 0.1.0

First release. A menu bar app that slides [Muse](https://muse.ai) out from the edge of the
screen so you can keep a conversation going without switching to a browser tab.

- Swipe two fingers in from the trackpad's right edge to open the panel, and again to close it.
  This replaces Notification Center's swipe; the app asks before changing that setting.
- `⌃⌥Space` toggles the panel from anywhere.
- Hosts the real muse.ai web app, so chat, replies and reactions work as on the website.
- Follows the system light and dark appearance.
- Uses no CPU while hidden, and frees the page's memory after 15 minutes out of sight.

Requires macOS 14 or later. Unofficial; not affiliated with Meta.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/viraatdas/muse-sidepanel/main/install.sh | bash
```

or download the DMG below and drag the app to Applications.
