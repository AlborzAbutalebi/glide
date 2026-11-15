import AppKit
import CoreGraphics

enum ActionGroup: String, CaseIterable, Identifiable {
    case mouse = "Mouse"
    case system = "System"
    case media = "Media"
    case editing = "Editing and tabs"
    case glide = "Mouse settings"
    case custom = "Custom"

    var id: String { rawValue }
}

enum MouseAction: String, Codable, CaseIterable, Identifiable {
    case passthrough, disabled
    case middleClick, back, forward
    case missionControl, appExpose, showDesktop, spaceLeft, spaceRight, spotlight, screenshot, lockScreen
    case playPause, nextTrack, previousTrack, volumeUp, volumeDown, mute
    case copy, paste, undo, redo, newTab, closeTab, nextTab, previousTab
    case toggleWheelMode, cycleDPI, toggleSmoothScrolling
    case customShortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .passthrough: "Default"
        case .disabled: "Do nothing"
        case .middleClick: "Middle click"
        case .back: "Back (⌘[)"
        case .forward: "Forward (⌘])"
        case .missionControl: "Mission Control"
        case .appExpose: "App windows (App Exposé)"
        case .showDesktop: "Show desktop"
        case .spaceLeft: "Desktop to the left"
        case .spaceRight: "Desktop to the right"
        case .spotlight: "Spotlight"
        case .screenshot: "Screenshot of an area"
        case .lockScreen: "Lock screen"
        case .playPause: "Play / pause"
        case .nextTrack: "Next track"
        case .previousTrack: "Previous track"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .mute: "Mute"
        case .copy: "Copy"
        case .paste: "Paste"
        case .undo: "Undo"
        case .redo: "Redo"
        case .newTab: "New tab"
        case .closeTab: "Close tab"
        case .nextTab: "Next tab"
        case .previousTab: "Previous tab"
        case .toggleWheelMode: "Switch ratchet / free-spin"
        case .cycleDPI: "Cycle DPI presets"
        case .toggleSmoothScrolling: "Turn smooth scrolling on/off"
        case .customShortcut: "Keyboard shortcut…"
        }
    }

    var symbol: String {
        switch self {
        case .passthrough: "arrow.uturn.backward.circle"
        case .disabled: "nosign"
        case .middleClick: "computermouse"
        case .back: "chevron.backward"
        case .forward: "chevron.forward"
        case .missionControl: "rectangle.3.group"
        case .appExpose: "rectangle.stack"
        case .showDesktop: "menubar.dock.rectangle"
        case .spaceLeft: "arrow.left.square"
        case .spaceRight: "arrow.right.square"
        case .spotlight: "magnifyingglass"
        case .screenshot: "camera.viewfinder"
        case .lockScreen: "lock"
        case .playPause: "playpause"
        case .nextTrack: "forward.end"
        case .previousTrack: "backward.end"
        case .volumeUp: "speaker.plus"
        case .volumeDown: "speaker.minus"
        case .mute: "speaker.slash"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .newTab: "plus.square.on.square"
        case .closeTab: "xmark.square"
        case .nextTab: "arrow.right.to.line"
        case .previousTab: "arrow.left.to.line"
        case .toggleWheelMode: "gearshape.arrow.triangle.2.circlepath"
        case .cycleDPI: "speedometer"
        case .toggleSmoothScrolling: "scroll"
        case .customShortcut: "keyboard"
        }
    }

    var group: ActionGroup {
        switch self {
        case .passthrough, .disabled, .middleClick, .back, .forward: .mouse
        case .missionControl, .appExpose, .showDesktop, .spaceLeft, .spaceRight, .spotlight, .screenshot, .lockScreen: .system
        case .playPause, .nextTrack, .previousTrack, .volumeUp, .volumeDown, .mute: .media
        case .copy, .paste, .undo, .redo, .newTab, .closeTab, .nextTab, .previousTab: .editing
        case .toggleWheelMode, .cycleDPI, .toggleSmoothScrolling: .glide
        case .customShortcut: .custom
        }
    }
}

/// Carries out actions: synthetic keys, media keys, system features and clicks.
/// Safe to call from any thread; the work happens on the main thread, in order.
final class ActionPerformer {
    /// Actions that change mouse settings (wheel mode, DPI, smooth scrolling).
    var settingsAction: ((MouseAction) -> Void)?

    func press(_ binding: ActionBinding) {
        DispatchQueue.main.async { self.run(binding, down: true) }
    }

    func release(_ binding: ActionBinding) {
        guard binding.action == .middleClick else { return }
        DispatchQueue.main.async { self.run(binding, down: false) }
    }

    /// Press and release in one go (gestures).
    func trigger(_ binding: ActionBinding) {
        press(binding)
        release(binding)
    }

    private func run(_ binding: ActionBinding, down: Bool) {
        let cmd = CGEventFlags.maskCommand, shift = CGEventFlags.maskShift, ctrl = CGEventFlags.maskControl
        switch binding.action {
        case .passthrough, .disabled: break
        case .middleClick: Self.middleButton(down: down)
        case .back: Self.keystroke(33, cmd)
        case .forward: Self.keystroke(30, cmd)
        case .missionControl: if !Self.dock("com.apple.expose.awake") { Self.hotKey(32, fallback: (126, ctrl.union(.maskSecondaryFn))) }
        case .appExpose: if !Self.dock("com.apple.expose.front.awake") { Self.hotKey(33, fallback: (125, ctrl.union(.maskSecondaryFn))) }
        case .showDesktop: if !Self.dock("com.apple.showdesktop.awake") { Self.hotKey(36, fallback: (103, .maskSecondaryFn)) }
        case .spaceLeft: Self.hotKey(79, fallback: (123, ctrl.union(.maskSecondaryFn)))
        case .spaceRight: Self.hotKey(81, fallback: (124, ctrl.union(.maskSecondaryFn)))
        case .spotlight: Self.hotKey(64, fallback: (49, cmd))
        case .screenshot: Self.keystroke(21, cmd.union(shift))
        case .lockScreen: Self.keystroke(12, cmd.union(ctrl))
        case .playPause: Self.mediaKey(16)
        case .nextTrack: Self.mediaKey(17)
        case .previousTrack: Self.mediaKey(18)
        case .volumeUp: Self.mediaKey(0)
        case .volumeDown: Self.mediaKey(1)
        case .mute: Self.mediaKey(7)
        case .copy: Self.keystroke(8, cmd)
        case .paste: Self.keystroke(9, cmd)
        case .undo: Self.keystroke(6, cmd)
        case .redo: Self.keystroke(6, cmd.union(shift))
        case .newTab: Self.keystroke(17, cmd)
        case .closeTab: Self.keystroke(13, cmd)
        case .nextTab: Self.keystroke(48, ctrl)
        case .previousTab: Self.keystroke(48, ctrl.union(shift))
        case .toggleWheelMode, .cycleDPI, .toggleSmoothScrolling: settingsAction?(binding.action)
        case .customShortcut:
            if let combo = binding.shortcut {
                Self.keystroke(CGKeyCode(combo.keyCode), CGEventFlags(rawValue: combo.modifiers))
            }
        }
    }

    // MARK: - Primitives

    static func keystroke(_ code: CGKeyCode, _ flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: kGlideEventMarker)
            e.post(tap: .cghidEventTap)
        }
    }

    static func middleButton(down: Bool) {
        let location = CGEvent(source: nil)?.location ?? .zero
        guard let e = CGEvent(mouseEventSource: nil, mouseType: down ? .otherMouseDown : .otherMouseUp,
                              mouseCursorPosition: location, mouseButton: .center) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: kGlideEventMarker)
        e.post(tap: .cghidEventTap)
    }

    /// NX_KEYTYPE media keys (volume, play, next...).
    static func mediaKey(_ key: Int) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                                 modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                                 timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                                 data1: (key << 16) | (state << 8), data2: -1) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - System features

    private typealias DockNotify = @convention(c) (CFString, Int32) -> Void
    private static let dockNotify: DockNotify? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let symbol = dlsym(handle, "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(symbol, to: DockNotify.self)
    }()

    /// Asks the Dock for Mission Control, App Exposé or Show Desktop directly.
    @discardableResult
    private static func dock(_ name: String) -> Bool {
        guard let dockNotify else { return false }
        dockNotify(name as CFString, 0)
        return true
    }

    private typealias GetHotKey = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt32>) -> Int32
    private static let getHotKey: GetHotKey? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSGetSymbolicHotKeyValue") else { return nil }
        return unsafeBitCast(symbol, to: GetHotKey.self)
    }()

    /// Presses the keyboard shortcut macOS has assigned to a system feature
    /// (System Settings > Keyboard > Keyboard Shortcuts), falling back to the default.
    private static func hotKey(_ id: Int32, fallback: (CGKeyCode, CGEventFlags)) {
        var code = fallback.0
        var flags = fallback.1
        if let getHotKey {
            var character: UInt16 = 0
            var virtualKey: UInt16 = 0
            var modifiers: UInt64 = 0
            let result = withUnsafeMutablePointer(to: &modifiers) {
                $0.withMemoryRebound(to: UInt32.self, capacity: 2) { getHotKey(id, &character, &virtualKey, $0) }
            }
            if result == 0, virtualKey != 0xFFFF {
                code = CGKeyCode(virtualKey)
                flags = CGEventFlags(rawValue: modifiers & 0x00FF_0000)
            }
        }
        keystroke(code, flags)
    }
}
