import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = PanelController()
    private var tracker: SwipeTracker?
    private var hotKey: HotKey?
    private var strips: [EdgeStrip] = []
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Muse Sidepanel")
        item.menu = makeStatusMenu()
        statusItem = item

        tracker = SwipeTracker(controller: controller)
        TrackpadEdge.shared.start(controller: controller)
        rebuildStrips()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // ⌃⌥Space
        hotKey = HotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey) { [weak self] in
            self?.controller.toggle()
        }

        if CommandLine.arguments.contains("--show") {
            controller.show()
        }
        offerEdgeSwipeIfNeeded()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.show()
        return false
    }

    // MARK: Edge strips

    private func rebuildStrips() {
        strips.forEach { $0.close() }
        strips = NSScreen.screens.map { EdgeStrip(screen: $0, side: Settings.side) }
    }

    @objc private func screensChanged() {
        rebuildStrips()
        controller.screensChanged()
    }

    // MARK: Menus

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let toggle = menu.addItem(withTitle: "Show Muse", action: #selector(togglePanel), keyEquivalent: " ")
        toggle.keyEquivalentModifierMask = [.control, .option]
        toggle.tag = Tag.toggle.rawValue
        menu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "")
        menu.addItem(withTitle: "Open in Browser", action: #selector(openInBrowser), keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: "Keep Open", action: #selector(togglePinned), keyEquivalent: "").tag = Tag.pinned.rawValue
        let sideItem = menu.addItem(withTitle: "Screen Edge", action: nil, keyEquivalent: "")
        let sideMenu = NSMenu()
        sideMenu.addItem(withTitle: "Left", action: #selector(useLeftSide), keyEquivalent: "").tag = Tag.left.rawValue
        sideMenu.addItem(withTitle: "Right", action: #selector(useRightSide), keyEquivalent: "").tag = Tag.right.rawValue
        sideItem.submenu = sideMenu
        menu.addItem(withTitle: "Trackpad Edge Swipe", action: #selector(toggleEdgeSwipe), keyEquivalent: "").tag = Tag.edgeSwipe.rawValue
        menu.addItem(withTitle: "Free Memory When Idle", action: #selector(toggleUnload), keyEquivalent: "").tag = Tag.unload.rawValue
        menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "").tag = Tag.login.rawValue
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Muse Sidepanel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private enum Tag: Int {
        case toggle = 1, pinned, left, right, unload, login, edgeSwipe
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        func state(_ on: Bool) -> NSControl.StateValue { on ? .on : .off }
        menu.item(withTag: Tag.toggle.rawValue)?.title = controller.isShown ? "Hide Muse" : "Show Muse"
        menu.item(withTag: Tag.pinned.rawValue)?.state = state(Settings.pinned)
        menu.item(withTag: Tag.edgeSwipe.rawValue)?.state = state(TrackpadEdge.shared.isEnabled)
        menu.item(withTag: Tag.unload.rawValue)?.state = state(Settings.unloadWhenIdle)
        menu.item(withTag: Tag.login.rawValue)?.state = state(SMAppService.mainApp.status == .enabled)
        if let sideMenu = menu.items.first(where: { $0.submenu != nil })?.submenu {
            sideMenu.item(withTag: Tag.left.rawValue)?.state = state(Settings.side == .left)
            sideMenu.item(withTag: Tag.right.rawValue)?.state = state(Settings.side == .right)
        }
    }

    /// Never shown (the app has no Dock icon); it exists so ⌘C, ⌘V, ⌘R… work inside the panel.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Muse", action: #selector(hidePanel), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
        appMenu.addItem(withTitle: "Quit Muse Sidepanel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Muse Sidepanel", action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        return main
    }

    // MARK: Actions

    @objc private func togglePanel() { controller.toggle() }
    @objc private func hidePanel() { controller.hide() }
    @objc private func reload() { controller.reload() }
    @objc private func openInBrowser() { controller.openInBrowser() }
    @objc private func togglePinned() { controller.togglePinned() }
    @objc private func toggleEdgeSwipe() { setEdgeSwipe(!TrackpadEdge.shared.isEnabled) }

    /// The panel takes the edge swipe by handing Notification Center's claim on it back or away.
    private func setEdgeSwipe(_ enabled: Bool) {
        NotificationCenterGesture.setEnabled(!enabled)
        TrackpadEdge.shared.isEnabled = enabled
    }

    /// First launch only: the edge swipe needs a system setting changed, so ask before touching it.
    private func offerEdgeSwipeIfNeeded() {
        let asked = "askedEdgeSwipe"
        guard NotificationCenterGesture.isEnabled, !UserDefaults.standard.bool(forKey: asked) else { return }
        UserDefaults.standard.set(true, forKey: asked)
        let alert = NSAlert()
        alert.messageText = "Open Muse with a trackpad edge swipe?"
        alert.informativeText = """
            Swiping two fingers in from the right edge of the trackpad normally opens Notification Center. \
            Muse Sidepanel can use that swipe instead. Notification Center stays available from the clock in \
            the menu bar, and you can change this any time from the Muse Sidepanel menu.
            """
        alert.addButton(withTitle: "Use Edge Swipe")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            setEdgeSwipe(true)
        }
    }

    @objc private func toggleUnload() { Settings.unloadWhenIdle.toggle() }
    @objc private func useLeftSide() { setSide(.left) }
    @objc private func useRightSide() { setSide(.right) }

    private func setSide(_ side: Side) {
        Settings.side = side
        rebuildStrips()
        controller.sideChanged()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t change Launch at Login"
            alert.runModal()
        }
    }
}
