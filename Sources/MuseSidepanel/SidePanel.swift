import AppKit

/// Borderless panel that takes keyboard focus without activating the app, so the app you
/// were working in stays frontmost while you type to Muse.
final class SidePanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The app is usually not active, so route shortcuts (copy, paste, reload…) to the main menu ourselves.
        super.performKeyEquivalent(with: event) || (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
    }
}

/// The visible card: translucent material, a slim header, and the web view below it.
final class CardView: NSView {
    static let cornerRadius: CGFloat = 16
    static let headerHeight: CGFloat = 36

    let webContainer = NSView()
    private let clip = NSView()
    private let material = NSVisualEffectView()
    private let header = NSView()
    private let spinner = NSProgressIndicator()
    private let resizeHandle = ResizeHandle()
    private var pinButton: NSButton!

    var onReload: (() -> Void)?
    var onOpenInBrowser: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onClose: (() -> Void)?
    var onResize: ((CGFloat) -> Void)? {
        get { resizeHandle.onResize }
        set { resizeHandle.onResize = newValue }
    }

    init() {
        // Start from a real size: autoresizing masks cannot scale up from an empty rect.
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 800))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -5)

        clip.wantsLayer = true
        clip.layer?.cornerRadius = Self.cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 0.5
        clip.frame = bounds
        clip.autoresizingMask = [.width, .height]
        addSubview(clip)

        // The material has to sit under the whole card, web view included. AppKit tells the window
        // server which parts of a window are opaque from view frames, and only refreshes that on a
        // display pass; without a behind-window effect view covering it, the web view's old
        // rectangle stays painted while the card slides.
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.maskImage = Self.maskImage(radius: Self.cornerRadius)
        material.frame = clip.bounds
        material.autoresizingMask = [.width, .height]
        clip.addSubview(material)

        header.frame = NSRect(x: 0, y: bounds.height - Self.headerHeight, width: bounds.width, height: Self.headerHeight)
        header.autoresizingMask = [.width, .minYMargin]
        clip.addSubview(header)

        webContainer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.headerHeight)
        webContainer.autoresizingMask = [.width, .height]
        clip.addSubview(webContainer)

        buildHeader()
        addSubview(resizeHandle)
        updateBorder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildHeader() {
        let title = NSTextField(labelWithString: "Muse")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        pinButton = iconButton("pin", "Keep open when clicking elsewhere", #selector(pinTapped))
        let stack = NSStackView(views: [
            title, spinner, spacer,
            iconButton("arrow.clockwise", "Reload (⌘R)", #selector(reloadTapped)),
            iconButton("arrow.up.forward.app", "Open in browser", #selector(browserTapped)),
            pinButton,
            iconButton("xmark", "Hide (⌘W)", #selector(closeTapped)),
        ])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.setCustomSpacing(8, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: Self.symbol(symbol, tip), target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.refusesFirstResponder = true
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private static func symbol(_ name: String, _ description: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration) ?? NSImage()
    }

    private static func maskImage(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: State

    func setLoading(_ loading: Bool) {
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func setPinned(_ pinned: Bool) {
        pinButton.image = Self.symbol(pinned ? "pin.fill" : "pin", "Keep open")
        pinButton.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
    }

    /// Puts the resize handle on the edge that faces the rest of the screen.
    func setSide(_ side: Side) {
        let width: CGFloat = 5
        resizeHandle.side = side
        resizeHandle.frame = NSRect(x: side == .right ? 0 : bounds.width - width, y: Self.cornerRadius,
                                    width: width, height: bounds.height - 2 * Self.cornerRadius)
        resizeHandle.autoresizingMask = side == .right ? [.height, .maxXMargin] : [.height, .minXMargin]
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius,
                                   cornerHeight: Self.cornerRadius, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            clip.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    @objc private func reloadTapped() { onReload?() }
    @objc private func browserTapped() { onOpenInBrowser?() }
    @objc private func pinTapped() { onTogglePin?() }
    @objc private func closeTapped() { onClose?() }
}

/// Thin strip on the card's inner edge; drag it to change the panel width.
final class ResizeHandle: NSView {
    var side = Side.right
    var onResize: ((CGFloat) -> Void)?
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        startX = NSEvent.mouseLocation.x
        startWidth = Settings.width
    }

    override func mouseDragged(with event: NSEvent) {
        let moved = NSEvent.mouseLocation.x - startX
        onResize?(startWidth + (side == .right ? -moved : moved))
    }
}

/// Invisible sliver along a screen edge. Scroll gestures that start with the pointer
/// resting here are what pull the panel out; it costs nothing until that happens.
final class EdgeStrip: NSPanel {
    static let thickness: CGFloat = 3

    init(screen: NSScreen, side: Side) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Stay clear of the corners so hot corners and the menu bar keep working.
        let inset: CGFloat = 60
        let frame = screen.frame
        setFrame(NSRect(x: side == .right ? frame.maxX - Self.thickness : frame.minX, y: frame.minY + inset,
                        width: Self.thickness, height: frame.height - 2 * inset), display: false)
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
