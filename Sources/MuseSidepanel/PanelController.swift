import AppKit

/// Shows, hides and slides the panel. `progress` runs from 0 (off-screen) to 1 (fully out).
/// The window itself never moves, only the card inside it, so the slide is pure compositing:
/// nothing is laid out or redrawn, including the page.
final class PanelController: NSObject, NSWindowDelegate {
    private static let margin: CGFloat = 10
    private static let shadowPad: CGFloat = 44
    private static let idleUnloadDelay: TimeInterval = 15 * 60

    let panel = SidePanel()
    let web = WebController()
    private let card = CardView()

    private(set) var isShown = false
    private(set) var progress: CGFloat = 0
    private var generation = 0
    private var modalDepth = 0
    private var idleTimer: Timer?

    override init() {
        super.init()
        let root = NSView()
        root.wantsLayer = true
        root.addSubview(card)
        panel.contentView = root
        panel.delegate = self

        card.setPinned(Settings.pinned)
        card.onReload = { [weak self] in self?.reload() }
        card.onOpenInBrowser = { [weak self] in self?.openInBrowser() }
        card.onTogglePin = { [weak self] in self?.togglePinned() }
        card.onClose = { [weak self] in self?.hide() }
        card.onResize = { [weak self] width in
            guard let self else { return }
            Settings.width = width
            self.place(on: self.panel.screen)
        }
        web.onLoadingChanged = { [weak self] in self?.card.setLoading($0) }
        web.onModal = { [weak self] presenting in
            guard let self else { return }
            self.modalDepth += presenting ? 1 : -1
            if !presenting, self.isShown { self.panel.makeKey() }
        }
    }

    // MARK: Show / hide

    func toggle() {
        if isShown { hide() } else { show() }
    }

    func show(on screen: NSScreen? = nil, velocity: CGFloat = 0) {
        prepare(on: screen)
        isShown = true
        panel.makeKey()
        if let webView = web.webView { panel.makeFirstResponder(webView) }
        animate(to: 1, velocity: velocity)
    }

    func hide(velocity: CGFloat = 0) {
        guard panel.isVisible else { return }
        isShown = false
        web.rememberLocation()
        let generation = self.generation
        animate(to: 0, velocity: velocity) { [weak self] in
            guard let self, generation == self.generation, !self.isShown else { return }
            self.panel.orderOut(nil)
            self.scheduleIdleUnload()
        }
    }

    // MARK: Finger-driven sliding

    func beginInteractive(on screen: NSScreen?) {
        prepare(on: screen)
    }

    func setProgress(_ value: CGFloat) {
        apply(progress: min(max(value, 0), 1))
    }

    /// `velocity` is in progress per second, so the settle animation carries on at finger speed.
    func finishInteractive(open: Bool, velocity: CGFloat = 0) {
        if open { show(on: panel.screen, velocity: velocity) } else { hide(velocity: velocity) }
    }

    // MARK: Actions

    func reload() {
        web.reload()
    }

    func openInBrowser() {
        NSWorkspace.shared.open(web.currentURL)
    }

    func togglePinned() {
        Settings.pinned.toggle()
        card.setPinned(Settings.pinned)
    }

    func sideChanged() {
        if panel.isVisible { place(on: panel.screen) }
    }

    func screensChanged() {
        if panel.isVisible { place(on: panel.screen) }
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if isShown, !Settings.pinned, modalDepth == 0 { hide() }
    }

    // MARK: Internals

    /// Gets the window on screen (still slid out of view if it was hidden) with the page loading.
    private func prepare(on screen: NSScreen?) {
        generation += 1
        idleTimer?.invalidate()
        idleTimer = nil
        web.ensureLoaded(in: card.webContainer)
        // Take over a slide that is still settling, from wherever it has got to.
        stopSpring()
        guard !panel.isVisible else { return }
        place(on: screen)
        panel.orderFrontRegardless()
    }

    private func place(on screen: NSScreen?) {
        guard let screen = screen ?? Self.screenUnderMouse() else { return }
        let visible = screen.visibleFrame
        let width = Settings.width + Self.margin + Self.shadowPad
        let x = Settings.side == .right ? visible.maxX - width : visible.minX
        panel.setFrame(NSRect(x: x, y: visible.minY, width: width, height: visible.height), display: false)
        card.frame = cardFrame(at: progress)
        card.setSide(Settings.side)
    }

    private func cardFrame(at progress: CGFloat) -> NSRect {
        let size = panel.frame.size
        let width = Settings.width
        let shownX = Settings.side == .right ? Self.shadowPad : Self.margin
        let hiddenX = Settings.side == .right ? size.width + 2 : -width - 2
        return NSRect(x: hiddenX + (shownX - hiddenX) * progress, y: Self.margin,
                      width: width, height: size.height - 2 * Self.margin)
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func apply(progress value: CGFloat) {
        progress = value
        if reduceMotion {
            card.setFrameOrigin(cardFrame(at: 1).origin)
            card.alphaValue = value
        } else {
            card.setFrameOrigin(cardFrame(at: value).origin)
            card.alphaValue = 1
        }
    }

    // MARK: Spring

    // A critically damped spring stepped once per display refresh. It starts at the speed the
    // fingers left the card at, never overshoots, and can be grabbed again mid-flight. The
    // display link only exists while the card is settling.
    private static let springRate: CGFloat = 18

    private var displayLink: CADisplayLink?
    private var springStart: CFTimeInterval = 0
    private var springTarget: CGFloat = 0
    private var springOffset: CGFloat = 0
    private var springDrift: CGFloat = 0
    private var springCompletion: (() -> Void)?

    private func animate(to target: CGFloat, velocity: CGFloat = 0, completion: (() -> Void)? = nil) {
        stopSpring()
        if reduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                progress = target
                card.setFrameOrigin(cardFrame(at: 1).origin)
                card.animator().alphaValue = target
            }, completionHandler: completion)
            return
        }
        springTarget = target
        springOffset = progress - target
        springDrift = min(max(velocity, -12), 12) + Self.springRate * springOffset
        springStart = CACurrentMediaTime()
        springCompletion = completion
        // Driven by the screen, not the view: a view's link pauses whenever macOS considers the
        // window occluded, which it does for a transparent panel whose card is still off to the side.
        guard let screen = panel.screen ?? NSScreen.main else {
            apply(progress: target)
            springCompletion = nil
            completion?()
            return
        }
        let link = screen.displayLink(target: self, selector: #selector(stepSpring))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func stepSpring(_ link: CADisplayLink) {
        let elapsed = CGFloat(link.targetTimestamp - springStart)
        let decay = exp(-Self.springRate * max(elapsed, 0))
        let offset = (springOffset + springDrift * elapsed) * decay
        if elapsed > 0.08, abs(offset) < 0.0015 || elapsed > 1 {
            apply(progress: springTarget)
            let completion = springCompletion
            stopSpring()
            completion?()
        } else {
            apply(progress: min(max(springTarget + offset, 0), 1))
        }
    }

    private func stopSpring() {
        displayLink?.invalidate()
        displayLink = nil
        springCompletion = nil
    }

    private func scheduleIdleUnload() {
        guard Settings.unloadWhenIdle else { return }
        let timer = Timer(timeInterval: Self.idleUnloadDelay, repeats: false) { [weak self] _ in
            guard let self, !self.panel.isVisible else { return }
            self.web.unload()
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private static func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
    }
}
