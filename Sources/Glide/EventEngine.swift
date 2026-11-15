import AppKit
import CoreGraphics
import GlideCore

/// Everything the event tap needs, as one value it can copy cheaply on every event.
struct EngineConfig {
    var active = false
    var vertical = ScrollFeel(pixelsPerClick: 100, smoothness: 0.07, acceleration: 0)
    var horizontal = ScrollFeel(pixelsPerClick: 66, smoothness: 0.07, acceleration: 0)
    var reverseVertical = false
    var reverseHorizontal = false
    var shiftHorizontal = true
    var modifierPassthrough = true
    var thumbWheel: ThumbWheelAction = .horizontalScroll
    /// CG button number (2 middle, 3 back, 4 forward) to binding. Only buttons Glide changes.
    var buttons: [Int64: ActionBinding] = [:]
    /// The frontmost app is a game or excluded: leave the wheel alone.
    var skipScrolling = false

    init() {}

    init(settings s: AppSettings, skipScrolling: Bool) {
        active = s.enabled
        let tau = s.smoothScrolling ? s.smoothness : 0
        vertical = ScrollFeel(pixelsPerClick: s.linesPerClick * AppSettings.pointsPerLine, smoothness: tau, acceleration: s.acceleration)
        horizontal = ScrollFeel(pixelsPerClick: s.horizontalLinesPerClick * AppSettings.pointsPerLine, smoothness: tau, acceleration: s.acceleration)
        reverseVertical = s.reverseVertical
        reverseHorizontal = s.reverseHorizontal
        shiftHorizontal = s.shiftScrollsHorizontally
        modifierPassthrough = s.modifierPassthrough
        thumbWheel = s.thumbWheelAction
        for (number, binding) in [(Int64(2), s.middleButton), (3, s.backButton), (4, s.forwardButton)] where binding.isActive {
            buttons[number] = binding
        }
        self.skipScrolling = skipScrolling
    }
}

/// macOS accelerates wheel events before anyone sees them, so the event alone can't tell
/// how many clicks the wheel actually turned. The HID input report can. This pairs each
/// wheel event with the raw report that caused it (reports normally arrive a few
/// milliseconds before the event) so every physical click counts exactly once.
struct WheelCorrelator {
    struct Owed {
        var time: Double
        /// Where the event's fallback single click went, so a late report can top it up.
        var axis: Int?
        var direction: Double
        var feel: ScrollFeel
    }

    var deviceActive = false
    private var pending: [[(time: Double, clicks: Int)]] = [[], []]
    private var owed: [[Owed]] = [[], []]
    private let window = 0.1

    /// A raw wheel report arrived. Returns extra clicks owed to an event that already went out.
    mutating func report(axis: Int, clicks: Int, time: Double) -> (Owed, Int)? {
        owed[axis].removeAll { time - $0.time > window }
        if !owed[axis].isEmpty {
            let o = owed[axis].removeFirst()
            return clicks > 1 ? (o, clicks - 1) : nil
        }
        pending[axis].removeAll { time - $0.time > window }
        pending[axis].append((time, clicks))
        return nil
    }

    /// A wheel event arrived on `axis`. Returns how many clicks it stands for, and whether
    /// that is a guess (the report hasn't arrived yet).
    mutating func take(axis: Int, time: Double) -> (clicks: Int, guessed: Bool) {
        pending[axis].removeAll { time - $0.time > window }
        if !pending[axis].isEmpty { return (pending[axis].removeFirst().clicks, false) }
        return (1, deviceActive)
    }

    mutating func owe(_ o: Owed, sourceAxis: Int) {
        owed[sourceAxis].append(o)
    }
}

/// The event tap: reshapes wheel scrolling and remaps the extra mouse buttons.
/// Lives on the driver thread.
final class EventEngine {
    private let configLock = UnfairLock()
    private var _config = EngineConfig()
    var config: EngineConfig {
        get { configLock.withLock { _config } }
        set { configLock.withLock { _config = newValue } }
    }

    let output = ScrollOutput()
    let actions: ActionPerformer
    var correlator = WheelCorrelator()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held: [Int64: ActionBinding] = [:]
    private var thumbAccumulator = 0.0

    private var stats = (events: 0, matched: 0, guessed: 0)

    func takeStats() -> (events: Int, matched: Int, guessed: Int) {
        defer { stats = (0, 0, 0) }
        return stats
    }

    init(actions: ActionPerformer) {
        self.actions = actions
    }

    var isInstalled: Bool { tap != nil }
    var isEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Creates the event tap on the current thread's run loop. Needs Accessibility permission.
    @discardableResult
    func install() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, context in
                                               Unmanaged<EventEngine>.fromOpaque(context!).takeUnretainedValue().handle(type, event)
                                           }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Log.info("event tap installed")
        return true
    }

    func reenableIfNeeded() {
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            Log.info("event tap re-enabled")
        }
    }

    /// A raw wheel value from the mouse's HID report (driver thread).
    func hidWheel(axis: Int, value: Int) {
        let now = CACurrentMediaTime()
        if let (owed, extra) = correlator.report(axis: axis, clicks: abs(value), time: now), let out = owed.axis {
            output.push(axis: out, clicks: owed.direction * Double(extra), feel: owed.feel, at: now)
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.info("event tap was disabled by macOS (\(type == .tapDisabledByTimeout ? "timeout" : "user input")); re-enabled")
            return Unmanaged.passUnretained(event)
        default:
            break
        }
        if event.getIntegerValueField(.eventSourceUserData) == kGlideEventMarker {
            return Unmanaged.passUnretained(event)
        }
        let config = self.config
        switch type {
        case .scrollWheel: return scroll(event, config)
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged: return button(type, event, config)
        default: return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Scrolling

    private func scroll(_ event: CGEvent, _ config: EngineConfig) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        // Trackpads and the Magic Mouse already scroll smoothly; leave them alone.
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 { return pass }

        let now = CACurrentMediaTime()
        let d1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let d2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        // Always pair the event with its HID report, even when passing it through,
        // so the pairing stays in step.
        let rawV: (clicks: Int, guessed: Bool) = d1 != 0 ? correlator.take(axis: 0, time: now) : (0, false)
        let rawH: (clicks: Int, guessed: Bool) = d2 != 0 ? correlator.take(axis: 1, time: now) : (0, false)
        stats.events += 1
        if rawV.guessed || rawH.guessed { stats.guessed += 1 } else { stats.matched += 1 }

        func oweNothing() {
            if rawV.guessed { correlator.owe(.init(time: now, axis: nil, direction: 0, feel: config.vertical), sourceAxis: 0) }
            if rawH.guessed { correlator.owe(.init(time: now, axis: nil, direction: 0, feel: config.horizontal), sourceAxis: 1) }
        }

        guard config.active, !config.skipScrolling else { oweNothing(); return pass }
        let flags = event.flags
        if config.modifierPassthrough, !flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty {
            // ⌘/⌥/⌃ + scroll means zoom and friends in many apps. Hand it over untouched.
            oweNothing()
            return pass
        }

        var v = Double(rawV.0) * (d1 > 0 ? 1 : -1)
        var h = Double(rawH.0) * (d2 > 0 ? 1 : -1)
        if d1 == 0 { v = 0 }
        if d2 == 0 { h = 0 }
        if config.reverseVertical { v = -v }
        var hFeel = config.horizontal
        var hFromThumb = h != 0
        if config.reverseHorizontal { h = -h }
        if flags.contains(.maskShift), config.shiftHorizontal, h == 0, v != 0 {
            // Shift + wheel scrolls sideways, at the vertical speed.
            h = v
            v = 0
            hFeel = config.vertical
            hFromThumb = false
        }

        if hFromThumb, config.thumbWheel != .horizontalScroll {
            thumbAction(h, config.thumbWheel)
            h = 0
        }

        if rawV.guessed {
            // The vertical click went to the vertical axis, or sideways if Shift turned it.
            let target: (Int, Double, ScrollFeel)? = v != 0 ? (0, v, config.vertical) : (h != 0 && !hFromThumb ? (1, h, hFeel) : nil)
            correlator.owe(.init(time: now, axis: target?.0, direction: (target?.1 ?? 0) < 0 ? -1 : 1, feel: target?.2 ?? config.vertical), sourceAxis: 0)
        }
        if rawH.guessed {
            correlator.owe(.init(time: now, axis: h != 0 && hFromThumb ? 1 : nil, direction: h < 0 ? -1 : 1, feel: hFeel), sourceAxis: 1)
        }

        if v != 0 { output.push(axis: 0, clicks: v, feel: config.vertical, at: now) }
        if h != 0 { output.push(axis: 1, clicks: h, feel: hFeel, at: now) }
        return nil
    }

    private func thumbAction(_ clicks: Double, _ action: ThumbWheelAction) {
        thumbAccumulator += clicks
        let perStep: Double = action == .volume ? 1 : 2
        while abs(thumbAccumulator) >= perStep {
            let forward = thumbAccumulator < 0
            thumbAccumulator += forward ? perStep : -perStep
            switch action {
            case .horizontalScroll: break
            case .switchTabs: actions.trigger(ActionBinding(forward ? .nextTab : .previousTab))
            case .volume: actions.trigger(ActionBinding(forward ? .volumeUp : .volumeDown))
            case .zoom:
                // ⌘= zooms in, ⌘- zooms out.
                let combo = KeyCombo(keyCode: forward ? 24 : 27, modifiers: CGEventFlags.maskCommand.rawValue, keyLabel: forward ? "=" : "-")
                actions.trigger(ActionBinding(.customShortcut, shortcut: combo))
            }
        }
    }

    // MARK: - Buttons

    private func button(_ type: CGEventType, _ event: CGEvent, _ config: EngineConfig) -> Unmanaged<CGEvent>? {
        let number = event.getIntegerValueField(.mouseEventButtonNumber)
        switch type {
        case .otherMouseDown:
            guard config.active, let binding = config.buttons[number] else { return Unmanaged.passUnretained(event) }
            held[number] = binding
            actions.press(binding)
            return nil
        case .otherMouseUp:
            guard let binding = held.removeValue(forKey: number) else { return Unmanaged.passUnretained(event) }
            actions.release(binding)
            return nil
        default: // dragged
            guard let binding = held[number] else { return Unmanaged.passUnretained(event) }
            if binding.action == .middleClick {
                event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            } else {
                // Keep hover effects working while a remapped button is held.
                event.type = .mouseMoved
            }
            return Unmanaged.passUnretained(event)
        }
    }
}
