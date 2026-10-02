import AppKit

/// Turns two-finger trackpad swipes into panel movement.
///
/// - Pointer resting on the screen edge: swipe inward to pull the panel out, outward to push it back.
/// - Pointer over the open panel: swipe toward the edge to dismiss it, unless the content under
///   the pointer can scroll that way itself.
///
/// It only sees scroll events aimed at this app's own windows, so nothing runs while you
/// scroll in other apps.
final class SwipeTracker {
    private enum Mode {
        case idle, edge, undecided, asking, closing, passthrough
    }

    private unowned let controller: PanelController
    private var monitor: Any?
    private var mode = Mode.idle
    private var gesture = 0
    private var gestureEndedWhileAsking = false
    private var dragging = false
    private var swallowMomentum = false
    private var inwardTotal: CGFloat = 0
    private var verticalTotal: CGFloat = 0
    private var scrollTotal: CGFloat = 0
    private var velocity: CGFloat = 0
    private var lastTime: TimeInterval = 0

    init(controller: PanelController) {
        self.controller = controller
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let onEdge = event.window is EdgeStrip
        guard onEdge || event.window === controller.panel else { return event }
        guard event.hasPreciseScrollingDeltas else { return onEdge ? nil : event }
        // The trackpad-edge swipe is already moving the panel; don't let its scroll events fight it.
        if TrackpadEdge.shared.isTracking { return nil }
        if !event.momentumPhase.isEmpty {
            return onEdge || swallowMomentum ? nil : event
        }

        // Follow the fingers, whatever the "natural scrolling" setting is.
        let finger = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        let inward = Settings.side == .right ? -finger : finger

        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            gesture += 1
            gestureEndedWhileAsking = false
            dragging = false
            swallowMomentum = false
            inwardTotal = 0
            verticalTotal = 0
            scrollTotal = 0
            velocity = 0
            lastTime = event.timestamp
            mode = onEdge ? .edge : (controller.isShown ? .undecided : .passthrough)
        }

        inwardTotal += inward
        verticalTotal += abs(event.scrollingDeltaY)
        scrollTotal += event.scrollingDeltaX

        switch mode {
        case .edge:
            if !dragging, abs(inwardTotal) > 6, abs(inwardTotal) > verticalTotal {
                dragging = true
                controller.beginInteractive(on: event.window?.screen)
            }
            if dragging { drag(inward, at: event.timestamp) }
        case .undecided:
            if verticalTotal > 6, verticalTotal >= abs(inwardTotal) {
                mode = .passthrough
            } else if inwardTotal < -5, -inwardTotal > 1.5 * verticalTotal {
                askPage(at: event.locationInWindow)
            }
        case .closing:
            drag(inward, at: event.timestamp)
        case .idle, .asking, .passthrough:
            break
        }

        let consumed = mode == .edge || mode == .closing
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            finish()
        }
        return consumed ? nil : event
    }

    private func drag(_ inward: CGFloat, at time: TimeInterval) {
        let step = inward / Settings.width
        let elapsed = max(time - lastTime, 1.0 / 240)
        lastTime = time
        // Progress per second, smoothed so one odd event at lift-off doesn't decide the outcome.
        velocity = velocity * 0.6 + (step / elapsed) * 0.4
        controller.setProgress(controller.progress + step)
    }

    private func finish() {
        if dragging {
            // A flick decides by direction; a slow drag by where it was let go.
            let open = abs(velocity) > 0.5 ? velocity > 0 : controller.progress > 0.5
            controller.finishInteractive(open: open, velocity: velocity)
            swallowMomentum = true
        }
        gestureEndedWhileAsking = mode == .asking
        mode = .idle
    }

    private func askPage(at point: NSPoint) {
        mode = .asking
        let asked = gesture
        // Content scrolls opposite to the scroll delta.
        let direction = scrollTotal > 0 ? -1 : 1
        controller.web.canScrollHorizontally(at: point, direction: direction) { [weak self] canScroll in
            guard let self, self.gesture == asked else { return }
            if self.mode == .asking {
                if canScroll {
                    self.mode = .passthrough
                } else {
                    self.mode = .closing
                    self.dragging = true
                    self.lastTime = ProcessInfo.processInfo.systemUptime
                    self.controller.beginInteractive(on: nil)
                }
            } else if self.gestureEndedWhileAsking, !canScroll {
                // The flick was over before the page answered.
                self.controller.hide()
            }
        }
    }
}
