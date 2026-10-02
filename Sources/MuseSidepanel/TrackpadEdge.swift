import AppKit

/// Toggles the panel with the gesture macOS normally gives to Notification Center: two fingers
/// sliding in from the trackpad's outer edge, wherever the pointer is. The same swipe opens the
/// panel when it is hidden and closes it when it is showing.
///
/// AppKit never reports where on the trackpad a touch landed, so this reads raw touch frames
/// from the private MultitouchSupport framework. The system's own edge gesture has to be
/// switched off (scripts/build-app.sh --install does that) or both would open.
final class TrackpadEdge {
    static let shared = TrackpadEdge()

    /// True while a swipe that started on the trackpad edge is driving the panel. Main thread only.
    private(set) var isTracking = false
    /// Whether the swipe in progress is closing the panel rather than opening it. Main thread only.
    private var closing = false

    /// Off while Notification Center still owns the edge swipe, so the two never open together.
    var isEnabled = !NotificationCenterGesture.isEnabled

    private weak var controller: PanelController?
    private var devices: [AnyObject] = []
    private var api: API?

    // Touch state, only touched on the framework's callback thread.
    private enum Phase { case waiting, candidate, dragging, rejected }
    private var phase = Phase.waiting
    private var origins: [Int32: (distance: Float, y: Float)] = [:]
    private var lastProgress: Float = 0
    private var lastTime: Double = 0
    private var velocity: Float = 0

    // Fractions of the trackpad's width. The zones are generous because a finger sliding in over
    // the bezel is first reported some way onto the pad, further in the faster it moves.
    private static let edgeZone: Float = 0.14
    private static let nearEdgeZone: Float = 0.38
    private static let startTravel: Float = 0.025
    private static let fullTravel: Float = 0.30

    func start(controller: PanelController) {
        self.controller = controller
        guard api == nil, let loaded = API() else { return }
        api = loaded
        attach()
        // Devices stop reporting after sleep or when a trackpad is (dis)connected.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(reattach), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func reattach() {
        guard let api else { return }
        for device in devices {
            api.unregister(device, TrackpadEdge.callback)
            api.stop(device)
        }
        devices = []
        // Touch frames may have stopped mid-swipe; don't leave the panel half out waiting for them.
        if isTracking, let controller {
            isTracking = false
            controller.finishInteractive(open: controller.progress > 0.5)
        }
        attach()
    }

    private func attach() {
        guard let api, let list = api.createList()?.takeRetainedValue() as? [AnyObject] else { return }
        devices = list
        for device in devices {
            api.register(device, TrackpadEdge.callback)
            api.start(device, 0)
        }
    }

    private static let callback: API.Callback = { _, touches, count, timestamp, _ in
        TrackpadEdge.shared.handle(touches?.assumingMemoryBound(to: Touch.self), Int(count), at: timestamp)
        return 0
    }

    private func handle(_ touches: UnsafePointer<Touch>?, _ count: Int, at time: Double) {
        // Only fingers actually pressing count; hovering and lifting contacts are still reported.
        var down = 0
        if let touches {
            for index in 0..<count where touches[index].state == 4 || touches[index].state == 5 { down += 1 }
        }
        if down == 0 {
            if phase == .dragging { finish() }
            if count == 0 {
                phase = .waiting
                origins.removeAll(keepingCapacity: true)
            }
            return
        }
        if phase == .rejected { return }
        guard isEnabled, let touches, down <= 2 else { return reject() }

        // Distance from the edge the panel lives on, 0 at the edge.
        let fromRight = Settings.side == .right
        var travel: Float = 0
        var drift: Float = 0
        for index in 0..<count where touches[index].state == 4 || touches[index].state == 5 {
            let touch = touches[index]
            let distance = fromRight ? 1 - touch.x : touch.x
            if let origin = origins[touch.identifier] {
                travel += distance - origin.distance
                drift += abs(touch.y - origin.y)
            } else {
                // Every finger has to come in over the edge; a swipe that starts mid-pad is just scrolling.
                let limit = origins.isEmpty ? Self.edgeZone : Self.nearEdgeZone
                guard phase != .dragging, distance <= limit else { return reject() }
                origins[touch.identifier] = (distance, touch.y)
                phase = .candidate
            }
        }
        guard down == 2 else { return }
        travel /= 2
        drift /= 2

        if phase == .candidate {
            // Mostly vertical movement near the edge is ordinary scrolling.
            if drift > 0.06, drift > travel { return reject() }
            guard travel > Self.startTravel else { return }
            phase = .dragging
            lastProgress = 0
            lastTime = time
            velocity = 0
            DispatchQueue.main.async { [weak self] in
                guard let self, let controller = self.controller else { return }
                self.isTracking = true
                self.closing = controller.isShown
                controller.beginInteractive(on: nil)
            }
        }

        let progress = (travel - Self.startTravel) / (Self.fullTravel - Self.startTravel)
        let step = CGFloat(progress - lastProgress)
        let elapsed = Float(max(time - lastTime, 1.0 / 240))
        if time > lastTime {
            velocity = velocity * 0.6 + ((progress - lastProgress) / elapsed) * 0.4
            lastTime = time
        }
        lastProgress = progress
        // Relative steps, so a card grabbed while it is still settling carries on from where it is.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isTracking, let controller = self.controller else { return }
            controller.setProgress(controller.progress + (self.closing ? -step : step))
        }
    }

    private func reject() {
        if phase == .dragging { finish() }
        phase = .rejected
    }

    private func finish() {
        let speed = CGFloat(velocity)
        phase = .rejected
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isTracking, let controller = self.controller else { return }
            self.isTracking = false
            // A flick decides by direction; a slow drag by where the card was let go.
            let toward: CGFloat = self.closing ? -1 : 1
            let open = abs(speed) > 0.5 ? speed * toward > 0 : controller.progress > 0.5
            controller.finishInteractive(open: open, velocity: speed * toward)
        }
    }

    // MARK: MultitouchSupport bridge

    /// Layout of MTTouch; only the identifier and normalized position are read.
    private struct Touch {
        var frame: Int32
        var timestamp: Double
        var identifier: Int32
        var state: Int32
        var fingerID: Int32
        var handID: Int32
        var x: Float
        var y: Float
        var velocityX: Float
        var velocityY: Float
        var size: Float
        var unknown1: Int32
        var angle: Float
        var majorAxis: Float
        var minorAxis: Float
        var absoluteX: Float
        var absoluteY: Float
        var absoluteVelocityX: Float
        var absoluteVelocityY: Float
        var unknown2: Int32
        var unknown3: Int32
        var density: Float
    }

    private struct API {
        typealias Callback = @convention(c) (AnyObject, UnsafeRawPointer?, Int32, Double, Int32) -> Int32

        let createList: @convention(c) () -> Unmanaged<CFArray>?
        let register: @convention(c) (AnyObject, Callback) -> Void
        let unregister: @convention(c) (AnyObject, Callback) -> Void
        let start: @convention(c) (AnyObject, Int32) -> Void
        let stop: @convention(c) (AnyObject) -> Void

        init?() {
            let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
            guard let handle = dlopen(path, RTLD_LAZY),
                  let createList = dlsym(handle, "MTDeviceCreateList"),
                  let register = dlsym(handle, "MTRegisterContactFrameCallback"),
                  let unregister = dlsym(handle, "MTUnregisterContactFrameCallback"),
                  let start = dlsym(handle, "MTDeviceStart"),
                  let stop = dlsym(handle, "MTDeviceStop")
            else { return nil }
            self.createList = unsafeBitCast(createList, to: (@convention(c) () -> Unmanaged<CFArray>?).self)
            self.register = unsafeBitCast(register, to: (@convention(c) (AnyObject, Callback) -> Void).self)
            self.unregister = unsafeBitCast(unregister, to: (@convention(c) (AnyObject, Callback) -> Void).self)
            self.start = unsafeBitCast(start, to: (@convention(c) (AnyObject, Int32) -> Void).self)
            self.stop = unsafeBitCast(stop, to: (@convention(c) (AnyObject) -> Void).self)
        }
    }
}
