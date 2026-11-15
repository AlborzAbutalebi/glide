import AppKit
import ApplicationServices
import IOKit.hid
import SwiftUI

/// Command-line checks, run from a terminal (they need the terminal's Accessibility access).
///
/// `--selftest` runs the real event tap and display-link output against synthetic wheel
/// clicks. A second tap at the end of the chain records and swallows every scroll and
/// button event while it runs, so nothing reaches the apps on screen.
///
/// `--probe` connects to the mouse over HID++ and prints what it reports.
enum SelfTest {
    final class Recorder {
        var events: [(time: Double, type: CGEventType, dy: Int64, dx: Int64, button: Int64, marked: Bool)] = []
        var start = CACurrentMediaTime()
        var port: CFMachPort?
        var disabled = 0
    }

    static func run() -> Int32 {
        Log.echo = true
        guard AXIsProcessTrusted() else {
            print("selftest needs Accessibility permission for the terminal")
            return 2
        }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.peripherals.glide")
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty {
            print("note: the Glide app is running; its own event tap sits in the same chain, so quit it first for clean results\n")
        }
        let driver = Driver()
        var settings = AppSettings()
        settings.backButton = ActionBinding(.disabled)
        settings.forwardButton = ActionBinding(.middleClick)
        driver.start(settings: settings, hid: false)
        guard driver.installTap() else {
            print("could not create the event tap")
            return 1
        }

        let recorder = Recorder()
        let types: [CGEventType] = [.scrollWheel, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let observer = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: { _, type, event, context in
            let r = Unmanaged<Recorder>.fromOpaque(context!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                r.disabled += 1
                if let port = r.port { CGEvent.tapEnable(tap: port, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard type == .scrollWheel || type == .otherMouseDown || type == .otherMouseUp else { return Unmanaged.passUnretained(event) }
            r.events.append((CACurrentMediaTime() - r.start, type,
                             event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                             event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
                             event.getIntegerValueField(.mouseEventButtonNumber),
                             event.getIntegerValueField(.eventSourceUserData) == kGlideEventMarker))
            return nil // swallow: keep the test away from real windows
        }, userInfo: Unmanaged.passUnretained(recorder).toOpaque()) else {
            print("could not create the observer tap")
            return 1
        }
        recorder.port = observer
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, observer, 0), .commonModes)
        CGEvent.tapEnable(tap: observer, enable: true)

        func wait(_ seconds: Double) { CFRunLoopRunInMode(.defaultMode, seconds, false) }
        func click(_ lines: Int32, flags: CGEventFlags = []) {
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
        func button(_ number: CGMouseButton, down: Bool) {
            let e = CGEvent(mouseEventSource: nil, mouseType: down ? .otherMouseDown : .otherMouseUp,
                            mouseCursorPosition: CGEvent(source: nil)!.location, mouseButton: number)!
            e.post(tap: .cghidEventTap)
        }
        var failures = 0
        func check(_ ok: Bool, _ message: String) {
            print(ok ? "  ok   " : "  FAIL ", message)
            if !ok { failures += 1 }
        }
        func scenario(_ name: String, _ body: () -> Void) -> [(time: Double, type: CGEventType, dy: Int64, dx: Int64, button: Int64, marked: Bool)] {
            print(name)
            recorder.events.removeAll()
            recorder.start = CACurrentMediaTime()
            body()
            return recorder.events
        }

        wait(0.3)

        var ev = scenario("one click down (3 lines = 100 pt, smooth)") { click(-1); wait(0.6) }
        let scrolls = ev.filter { $0.type == .scrollWheel }
        check(!scrolls.contains { !$0.marked }, "the original wheel event never reached apps")
        check(scrolls.reduce(0) { $0 + $1.dy } == -100, "total \(scrolls.reduce(0) { $0 + $1.dy }) pt == -100")
        check(scrolls.count >= 8, "spread over \(scrolls.count) frames")
        if scrolls.count > 2 {
            let gaps = zip(scrolls.dropFirst(), scrolls).map { ($0.time - $1.time) * 1000 }
            let sorted = gaps.sorted()
            print(String(format: "         first event %.1f ms after the click; frame gap median %.1f ms (min %.1f, max %.1f); last event at %.0f ms",
                         scrolls[0].time * 1000, sorted[sorted.count / 2], sorted.first!, sorted.last!, scrolls.last!.time * 1000))
            print("         deltas:", scrolls.map { String($0.dy) }.joined(separator: " "))
        }

        ev = scenario("five clicks, 80 ms apart") { for _ in 0..<5 { click(-1); wait(0.08) }; wait(0.6) }
        check(ev.reduce(0) { $0 + $1.dy } == -500, "total \(ev.reduce(0) { $0 + $1.dy }) pt == -500 (every click the same distance)")

        ev = scenario("reversal: three clicks down, then one up") {
            for _ in 0..<3 { click(-1); wait(0.03) }
            click(1)
            wait(0.6)
        }
        if let upIndex = ev.firstIndex(where: { $0.dy > 0 }) {
            check(!ev[upIndex...].contains { $0.dy < 0 }, "turns around at once, no leftover downward motion")
        } else {
            check(false, "no upward motion after the up-click")
        }

        ev = scenario("shift + click scrolls sideways") { click(-1, flags: .maskShift); wait(0.6) }
        check(ev.reduce(0) { $0 + $1.dx } == -100 && ev.allSatisfy { $0.dy == 0 }, "horizontal total \(ev.reduce(0) { $0 + $1.dx }) == -100, no vertical")

        ev = scenario("⌘ + click is left alone (zoom shortcuts)") { click(-1, flags: .maskCommand); wait(0.3) }
        check(ev.count == 1 && !ev[0].marked, "passed through unchanged")

        settings.smoothScrolling = false
        driver.update(settings: settings)
        ev = scenario("smooth scrolling off: linear, instant") { click(-1); wait(0.2) }
        check(ev.count == 1 && ev[0].dy == -100, "one event of -100 (got \(ev.map { $0.dy }))")

        settings.reverseVertical = true
        driver.update(settings: settings)
        ev = scenario("reverse direction") { click(-1); wait(0.2) }
        check(ev.reduce(0) { $0 + $1.dy } == 100, "total \(ev.reduce(0) { $0 + $1.dy }) == +100")

        ev = scenario("back button set to 'Do nothing'") { button(CGMouseButton(rawValue: 3)!, down: true); button(CGMouseButton(rawValue: 3)!, down: false); wait(0.2) }
        check(ev.isEmpty, "button swallowed")

        ev = scenario("forward button set to 'Middle click'") { button(CGMouseButton(rawValue: 4)!, down: true); wait(0.05); button(CGMouseButton(rawValue: 4)!, down: false); wait(0.2) }
        check(ev.count == 2 && ev.allSatisfy { $0.button == 2 && $0.marked }, "became a middle click (got buttons \(ev.map { $0.button }))")

        settings.enabled = false
        driver.update(settings: settings)
        ev = scenario("paused: everything passes through") { click(-1); wait(0.2) }
        check(ev.count == 1 && !ev[0].marked, "original event passed through (saw \(ev.map { "\($0.type == .scrollWheel ? "scroll" : "button") dy=\($0.dy) \($0.marked ? "glide" : "original")" }))")

        print("observer tap disabled by macOS \(recorder.disabled) time(s); engine tap enabled: \(driver.engine.isEnabled)")
        CGEvent.tapEnable(tap: observer, enable: false)
        print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Snapshot

    /// Renders each settings pane to a PNG, using the values the MX Master 3S reported.
    @MainActor
    static func snapshot(to directory: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let model = AppModel.shared
        var mouse = MouseState(name: "MX Master 3S", productID: 0xB034, transport: "Bluetooth Low Energy")
        mouse.firmware = "RBM22.00_0003"
        mouse.protocolVersion = "4.5"
        mouse.battery = 75
        mouse.dpi = 1000
        mouse.dpiDefault = 1000
        mouse.supportsDPI = true
        mouse.supportsSmartShift = true
        mouse.freeSpin = false
        mouse.smartShiftThreshold = 10
        mouse.smartShiftDefault = 10
        mouse.ratchetsPerRotation = 24
        mouse.hiResMultiplier = 15
        mouse.hasGestureButton = true
        mouse.hasModeShiftButton = true
        mouse.hasThumbWheel = true
        mouse.host = 1
        mouse.hostCount = 3
        let attention = CommandLine.arguments.contains("--needs-permission")
        model.preview(mouse: mouse, accessibility: !attention, hid: .connected)

        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let shots: [(String, AnyView, CGSize)] = [
            ("main", AnyView(MainView()), CGSize(width: 880, height: 680)),
            ("scrolling", AnyView(ScrollingPane()), CGSize(width: 680, height: 1500)),
            ("wheel", AnyView(WheelPane()), CGSize(width: 680, height: 760)),
            ("buttons", AnyView(ButtonsPane()), CGSize(width: 680, height: 1000)),
            ("pointer", AnyView(PointerPane()), CGSize(width: 680, height: 820)),
            ("general", AnyView(GeneralPane()), CGSize(width: 680, height: 900)),
        ]
        for (name, view, size) in shots {
            let host = NSHostingView(rootView: view.environmentObject(model)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            if CommandLine.arguments.contains("--light") { window.appearance = NSAppearance(named: .aqua) }
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
        }
        return 0
    }

    // MARK: - Probe

    static func probe(write: Bool) -> Int32 {
        Log.echo = true
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D, kIOHIDDeviceUsagePageKey: 0xFF43, kIOHIDDeviceUsageKey: 0x0202] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let opened = IOHIDManagerOpen(manager, 0)
        guard opened == kIOReturnSuccess, let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first else {
            print(String(format: "no Logitech HID++ mouse found (open 0x%08x)", opened))
            return 1
        }
        let hid = HIDPPDevice(device: device)
        hid.attach()
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
        let mouse = LogitechMouse(hid: hid, name: name, productID: IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0)
        var result: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                try mouse.initialize()
                let s = mouse.state
                print("""
                name        \(s.name)  (HID++ \(s.protocolVersion ?? "?"), firmware \(s.firmware ?? "?"))
                battery     \(s.battery.map { "\($0)%" } ?? "?")\(s.charging ? " charging" : "")
                DPI         \(s.dpi ?? 0)  (range \(s.dpiMin)–\(s.dpiMax), step \(s.dpiStep), default \(s.dpiDefault ?? 0))
                wheel       \(s.wheelMode?.title ?? "?")  (free-spin \(s.freeSpin ?? false), SmartShift threshold \(s.smartShiftThreshold ?? -1), default \(s.smartShiftDefault ?? -1))
                wheel info  \(s.ratchetsPerRotation ?? 0) clicks per turn, hi-res x\(s.hiResMultiplier ?? 0)
                buttons     gesture \(s.hasGestureButton), mode shift \(s.hasModeShiftButton), thumb wheel \(s.hasThumbWheel)
                host        \(s.host ?? 0) of \(s.hostCount ?? 0)
                """)
                if write {
                    // Write back exactly what the mouse already has, to exercise the write path.
                    if let dpi = s.dpi { try mouse.setDPI(dpi) }
                    if let mode = s.wheelMode { try mouse.setWheel(mode, threshold: s.smartShiftThreshold ?? 10) }
                    let after = mouse.state
                    print("write-back  DPI \(after.dpi ?? 0), wheel \(after.wheelMode?.title ?? "?") threshold \(after.smartShiftThreshold ?? -1)")
                    if after.dpi != s.dpi || after.wheelMode != s.wheelMode || after.smartShiftThreshold != s.smartShiftThreshold { result = 1 }
                }
            } catch {
                print("probe failed: \(error)")
                result = 1
            }
        }
        while done.wait(timeout: .now()) == .timedOut { CFRunLoopRunInMode(.defaultMode, 0.02, true) }
        return result
    }
}
