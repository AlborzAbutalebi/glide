import AppKit
import IOKit.hid

enum HIDStatus: Equatable {
    case searching
    case connected
    case needsInputMonitoring
    case failed(String)
}

/// Owns the event tap, the Logitech HID++ connection and everything that runs off the
/// main thread. The UI talks to it through `AppModel`.
final class Driver {
    let actions = ActionPerformer()
    let engine: EventEngine
    private let thread = RunLoopThread(name: "Glide driver")
    private let hidQueue = DispatchQueue(label: "glide.hidpp", qos: .userInitiated)

    /// Called on the main thread whenever the mouse or its state changes.
    var onMouse: ((MouseState?) -> Void)?
    var onHIDStatus: ((HIDStatus) -> Void)?

    private let lock = UnfairLock()
    private var _settings = AppSettings()
    private var _mouse: LogitechMouse?
    private var settings: AppSettings { lock.withLock { _settings } }
    private var mouse: LogitechMouse? {
        get { lock.withLock { _mouse } }
        set { lock.withLock { _mouse = newValue } }
    }
    private var skipScrolling = false
    private var hardwareDirty = false

    // Driver-thread state
    private var manager: IOHIDManager?
    private var gestureDown = false
    private var gestureFired = false
    private var gestureDX = 0
    private var gestureDY = 0
    private var modeShiftDown = false

    init() {
        engine = EventEngine(actions: actions)
    }

    func start(settings: AppSettings, hid: Bool = true) {
        lock.withLock { _settings = settings }
        engine.config = EngineConfig(settings: settings, skipScrolling: false)
        thread.startAndWait()
        if hid { thread.async { self.openHID() } }
    }

    /// Creates the event tap. Returns false until Accessibility permission is granted.
    func installTap() -> Bool {
        thread.sync { self.engine.install() }
    }

    func checkTap() {
        thread.async { self.engine.reenableIfNeeded() }
    }

    /// Notes how many wheel events were paired with the mouse's raw report.
    func logStats() {
        thread.async {
            let s = self.engine.takeStats()
            if s.events > 0 { Log.info("wheel events: \(s.events), paired with the raw report: \(s.matched), single-click guess: \(s.guessed)") }
        }
    }

    func update(settings: AppSettings) {
        lock.withLock { _settings = settings }
        engine.config = EngineConfig(settings: settings, skipScrolling: skipScrolling)
        if !settings.enabled { engine.output.stopAll() }
        scheduleHardwareApply(force: false)
    }

    func setSkipScrolling(_ skip: Bool) {
        skipScrolling = skip
        engine.config = EngineConfig(settings: settings, skipScrolling: skip)
    }

    // MARK: - HID

    /// (Re)opens the HID manager, e.g. after Input Monitoring is granted.
    func restartHID() {
        thread.async {
            if let m = self.mouse { self.detach(m) }
            if let manager = self.manager {
                IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
                IOHIDManagerClose(manager, 0)
                self.manager = nil
            }
            self.openHID()
        }
    }

    private func openHID() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Logitech devices that speak HID++ over Bluetooth expose vendor page 0xFF43, usage 0x0202.
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x046D,
            kIOHIDDeviceUsagePageKey: 0xFF43,
            kIOHIDDeviceUsageKey: 0x0202,
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<Driver>.fromOpaque(context!).takeUnretainedValue().matched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<Driver>.fromOpaque(context!).takeUnretainedValue().removed(device)
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            Unmanaged<Driver>.fromOpaque(context!).takeUnretainedValue().value(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        if result == kIOReturnNotPermitted {
            Log.info("HID access needs Input Monitoring permission")
            publish(status: .needsInputMonitoring)
        } else if result != kIOReturnSuccess {
            Log.info(String(format: "HID manager open returned 0x%08x", result))
        }
        if mouse == nil, result == kIOReturnSuccess { publish(status: .searching) }
    }

    private func matched(_ device: IOHIDDevice) {
        guard mouse == nil else { return }
        let open = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard open == kIOReturnSuccess else {
            Log.info(String(format: "could not open the mouse (0x%08x)", open))
            publish(status: open == kIOReturnNotPermitted ? .needsInputMonitoring : .failed(String(format: "0x%08x", open)))
            return
        }
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Logitech mouse"
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        let hid = HIDPPDevice(device: device)
        hid.onNotification = { [weak self] feature, event, params in self?.notification(feature, event, params) }
        hid.attach()
        let mouse = LogitechMouse(hid: hid, name: name, productID: product)
        self.mouse = mouse
        engine.correlator.deviceActive = true
        Log.info(String(format: "found %@ (product 0x%04x, %@)", name, product, transport))
        hidQueue.async {
            do {
                try mouse.initialize()
            } catch {
                Log.info("HID++ setup failed: \(error)")
            }
            self.applyHardware(to: mouse, force: true)
            self.publish(mouse)
            self.publish(status: .connected)
        }
    }

    private func removed(_ device: IOHIDDevice) {
        guard let m = mouse, CFEqual(m.hid.device, device) else { return }
        Log.info("mouse disconnected")
        detach(m)
        publish(status: .searching)
    }

    private func detach(_ m: LogitechMouse) {
        m.hid.detach()
        mouse = nil
        engine.correlator.deviceActive = false
        gestureDown = false
        modeShiftDown = false
        publish(nil as LogitechMouse?)
    }

    /// Raw HID values from the mouse: used to count real wheel clicks.
    private func value(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element)
        let v = IOHIDValueGetIntegerValue(value)
        guard v != 0 else { return }
        if page == 0x01, usage == 0x38 {
            engine.hidWheel(axis: 0, value: v)
        } else if page == 0x0C, usage == 0x238 {
            engine.hidWheel(axis: 1, value: v)
        }
    }

    // MARK: - Notifications (driver thread)

    private func notification(_ feature: UInt8, _ event: UInt8, _ p: [UInt8]) {
        guard let mouse else { return }
        if feature == mouse.featureIndex(of: .reprogControls) {
            if event == 0 { divertedButtons(p) } else if event == 1 { rawMovement(p) }
        } else if feature == mouse.featureIndex(of: .unifiedBattery) || feature == mouse.featureIndex(of: .battery) {
            let unified = feature == mouse.featureIndex(of: .unifiedBattery)
            hidQueue.async {
                mouse.applyBattery(p, unified: unified)
                self.publish(mouse)
            }
        } else if feature == mouse.featureIndex(of: .wirelessStatus) {
            // The mouse woke up or reconnected and may have forgotten Glide's settings.
            Log.info("mouse reconnected; re-applying settings")
            hidQueue.async {
                mouse.forgetApplied()
                self.applyHardware(to: mouse, force: true)
                try? mouse.readBattery()
                self.publish(mouse)
            }
        } else if feature == mouse.featureIndex(of: .hiResWheel), event == 1 {
            hidQueue.async {
                try? mouse.readWheel()
                self.publish(mouse)
            }
        }
    }

    private func divertedButtons(_ p: [UInt8]) {
        var pressed = Set<UInt16>()
        for k in stride(from: 0, to: min(8, p.count - 1), by: 2) {
            let cid = UInt16(p[k]) << 8 | UInt16(p[k + 1])
            if cid != 0 { pressed.insert(cid) }
        }
        let s = settings
        let gestureNow = pressed.contains(ControlID.gesture)
        if gestureNow, !gestureDown {
            gestureDown = true
            gestureFired = false
            gestureDX = 0
            gestureDY = 0
        } else if !gestureNow, gestureDown {
            gestureDown = false
            if !gestureFired, s.enabled { actions.trigger(s.gestureButton) }
        }
        let modeNow = pressed.contains(ControlID.modeShift)
        if modeNow, !modeShiftDown, s.enabled { actions.trigger(s.modeShiftButton) }
        modeShiftDown = modeNow
    }

    private func rawMovement(_ p: [UInt8]) {
        guard gestureDown, !gestureFired, p.count >= 4 else { return }
        gestureDX += Int(Int16(bitPattern: UInt16(p[0]) << 8 | UInt16(p[1])))
        gestureDY += Int(Int16(bitPattern: UInt16(p[2]) << 8 | UInt16(p[3])))
        let s = settings
        let dpi = Double(mouse?.state.dpi ?? 1000)
        let threshold = max(40.0, dpi * 0.1) // about 2.5 mm of hand movement
        guard s.gestureMovementActive, Double(gestureDX * gestureDX + gestureDY * gestureDY) > threshold * threshold else { return }
        gestureFired = true
        let binding = abs(gestureDX) > abs(gestureDY)
            ? (gestureDX > 0 ? s.gestureRight : s.gestureLeft)
            : (gestureDY > 0 ? s.gestureDown : s.gestureUp)
        actions.trigger(binding)
    }

    // MARK: - Hardware settings (HID++ queue)

    private func scheduleHardwareApply(force: Bool) {
        lock.withLock { hardwareDirty = true }
        hidQueue.async {
            let dirty = self.lock.withLock { () -> Bool in
                defer { self.hardwareDirty = false }
                return self.hardwareDirty
            }
            guard dirty, let mouse = self.mouse else { return }
            self.applyHardware(to: mouse, force: force)
            self.publish(mouse)
        }
    }

    private func applyHardware(to mouse: LogitechMouse, force: Bool) {
        let s = settings
        let st = mouse.state
        do {
            if let dpi = s.dpi, st.supportsDPI, force || mouse.appliedDPI != dpi {
                try mouse.setDPI(dpi)
            }
            if let mode = s.wheelMode, st.supportsSmartShift {
                let last = mouse.appliedWheel
                if force || last?.0 != mode || (mode == .smartShift && last?.1 != s.smartShiftThreshold) {
                    try mouse.setWheel(mode, threshold: s.smartShiftThreshold)
                }
            }
            if st.hasGestureButton {
                let gestures = s.enabled && s.gestureMovementActive
                let divert = s.enabled && (gestures || s.gestureButton.isActive)
                try mouse.setDiversion(ControlID.gesture, divert: divert, rawXY: gestures)
            }
            if st.hasModeShiftButton {
                try mouse.setDiversion(ControlID.modeShift, divert: s.enabled && s.modeShiftButton.isActive, rawXY: false)
            }
        } catch {
            Log.info("could not apply mouse settings: \(error)")
        }
        if force || mouse.appliedPointerAcceleration != s.pointerAcceleration {
            let wanted = s.pointerAcceleration
            let product = st.productID
            DispatchQueue.main.async { PointerTuning.apply(wanted, productID: product) }
            mouse.appliedPointerAcceleration = wanted
        }
    }

    /// Re-reads wheel mode and battery (for live display).
    func refresh() {
        hidQueue.async {
            guard let mouse = self.mouse else { return }
            try? mouse.readWheel()
            try? mouse.readBattery()
            self.publish(mouse)
        }
    }

    /// Re-applies everything, e.g. after the Mac wakes up.
    func reapplyAll() {
        hidQueue.async {
            guard let mouse = self.mouse else { return }
            mouse.forgetApplied()
            self.applyHardware(to: mouse, force: true)
            self.publish(mouse)
        }
    }

    func toggleWheelMode(completion: @escaping (WheelMode?) -> Void) {
        hidQueue.async {
            guard let mouse = self.mouse else { return }
            try? mouse.toggleWheelMode()
            self.publish(mouse)
            let mode = mouse.state.wheelMode
            DispatchQueue.main.async { completion(mode) }
        }
    }

    /// Gives the buttons back to the mouse. Called when quitting so nothing is left diverted.
    func shutdown() {
        guard let mouse else { return }
        let done = DispatchSemaphore(value: 0)
        hidQueue.async {
            try? mouse.setDiversion(ControlID.gesture, divert: false, rawXY: false)
            try? mouse.setDiversion(ControlID.modeShift, divert: false, rawXY: false)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
        PointerTuning.apply(.system, productID: mouse.state.productID)
    }

    // MARK: - Publishing

    private func publish(_ mouse: LogitechMouse?) {
        let state = mouse?.state
        DispatchQueue.main.async { self.onMouse?(state) }
    }

    private func publish(status: HIDStatus) {
        DispatchQueue.main.async { self.onHIDStatus?(status) }
    }
}

/// Per-mouse pointer acceleration, set on the mouse's HID service only. macOS resets it
/// when the mouse reconnects; Glide applies it again each time.
enum PointerTuning {
    private static var changed = Set<Int>()

    static func apply(_ mode: PointerAcceleration, productID: Int) {
        guard mode == .off || changed.contains(productID) else { return }
        let linear: Bool
        if mode == .off {
            linear = true
            changed.insert(productID)
        } else {
            linear = CFPreferencesCopyAppValue("com.apple.mouse.linear" as CFString, kCFPreferencesAnyApplication) as? Bool ?? false
            changed.remove(productID)
        }
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [AnyObject] else { return }
        var count = 0
        for object in services {
            let service = unsafeBitCast(object, to: IOHIDServiceClient.self)
            let vendor = IOHIDServiceClientCopyProperty(service, kIOHIDVendorIDKey as CFString) as? Int
            let product = IOHIDServiceClientCopyProperty(service, kIOHIDProductIDKey as CFString) as? Int
            guard vendor == 0x046D, product == productID,
                  IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0 else { continue }
            if IOHIDServiceClientSetProperty(service, "HIDUseLinearScalingMouseAcceleration" as CFString, linear as CFBoolean) { count += 1 }
        }
        Log.info("pointer acceleration \(linear ? "off (linear)" : "on") for \(count) service(s)")
    }
}
