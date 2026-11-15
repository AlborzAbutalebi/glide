import Foundation

enum WheelMode: String, Codable, CaseIterable, Identifiable {
    case ratchet, smartShift, freeSpin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ratchet: "Ratchet"
        case .smartShift: "SmartShift"
        case .freeSpin: "Free-spin"
        }
    }

    var detail: String {
        switch self {
        case .ratchet: "Click by click, like a normal scroll wheel. Never spins free on its own."
        case .smartShift: "Clicks normally, but lets go and spins free when you flick the wheel fast."
        case .freeSpin: "Always spins freely with no clicks, for flying through long pages."
        }
    }

    var symbol: String {
        switch self {
        case .ratchet: "gearshape"
        case .smartShift: "wand.and.stars"
        case .freeSpin: "tornado"
        }
    }
}

enum ThumbWheelAction: String, Codable, CaseIterable, Identifiable {
    case horizontalScroll, switchTabs, zoom, volume

    var id: String { rawValue }

    var title: String {
        switch self {
        case .horizontalScroll: "Scroll sideways"
        case .switchTabs: "Switch tabs"
        case .zoom: "Zoom in and out"
        case .volume: "Change volume"
        }
    }
}

enum PointerAcceleration: String, Codable, CaseIterable, Identifiable {
    case system, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "macOS setting"
        case .off: "Off (linear)"
        }
    }
}

/// A keyboard shortcut a button can send.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt16
    /// CGEventFlags bits (command, shift, option, control, fn).
    var modifiers: UInt64
    var keyLabel: String

    var display: String {
        var s = ""
        if modifiers & 0x40000 != 0 { s += "⌃" }
        if modifiers & 0x80000 != 0 { s += "⌥" }
        if modifiers & 0x20000 != 0 { s += "⇧" }
        if modifiers & 0x100000 != 0 { s += "⌘" }
        return s + keyLabel
    }
}

struct ActionBinding: Codable, Equatable {
    var action: MouseAction
    var shortcut: KeyCombo?

    init(_ action: MouseAction, shortcut: KeyCombo? = nil) {
        self.action = action
        self.shortcut = shortcut
    }

    /// True when Glide has to take the button over to do this.
    var isActive: Bool { action != .passthrough && !(action == .customShortcut && shortcut == nil) }
}

struct AppSettings: Codable, Equatable {
    var enabled = true

    // Scrolling
    var smoothScrolling = true
    var linesPerClick: Double = 3
    var smoothness: Double = 0.07
    var acceleration: Double = 0
    var reverseVertical = false
    var horizontalLinesPerClick: Double = 2
    var reverseHorizontal = false
    var thumbWheelAction: ThumbWheelAction = .horizontalScroll
    var shiftScrollsHorizontally = true
    var modifierPassthrough = true
    var skipGames = true
    var excludedApps: [String] = []

    // Scroll wheel hardware. nil means "leave it as the mouse has it".
    var wheelMode: WheelMode?
    var smartShiftThreshold: Int = 10

    // Buttons
    var middleButton = ActionBinding(.passthrough)
    var backButton = ActionBinding(.passthrough)
    var forwardButton = ActionBinding(.passthrough)
    var gestureButton = ActionBinding(.missionControl)
    var gesturesEnabled = true
    var gestureUp = ActionBinding(.missionControl)
    var gestureDown = ActionBinding(.appExpose)
    var gestureLeft = ActionBinding(.spaceLeft)
    var gestureRight = ActionBinding(.spaceRight)
    var modeShiftButton = ActionBinding(.passthrough)

    // Pointer. dpi nil means "leave it as the mouse has it".
    var dpi: Int?
    var dpiPresets: [Int] = [800, 1200, 1600, 2400]
    var pointerAcceleration: PointerAcceleration = .system

    // General
    var showBatteryInMenuBar = true
    var hasLaunchedBefore = false

    /// One "line" of scrolling, in points. Three lines per click is the classic wheel.
    static let pointsPerLine = 100.0 / 3.0

    var gestureMovementActive: Bool {
        gesturesEnabled && [gestureUp, gestureDown, gestureLeft, gestureRight].contains { $0.isActive && $0.action != .disabled }
    }
}

extension AppSettings {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Glide", isDirectory: true)
    }

    static var fileURL: URL { folder.appendingPathComponent("settings.json") }

    /// Loads saved settings on top of the defaults, so settings added in later versions
    /// get their default value instead of discarding the whole file.
    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(AppSettings()),
              var merged = (try? JSONSerialization.jsonObject(with: defaultsData)) as? [String: Any]
        else { return AppSettings() }
        merged.merge(stored) { _, saved in saved }
        if let mergedData = try? JSONSerialization.data(withJSONObject: merged),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: mergedData) {
            return settings
        }
        Log.info("settings file could not be read; using defaults")
        return AppSettings()
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: AppSettings.folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: AppSettings.fileURL, options: .atomic)
        } catch {
            Log.info("could not save settings: \(error)")
        }
    }
}
