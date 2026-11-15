import Foundation
import IOKit.hid

/// HID++ 2.0 feature IDs used by Glide.
enum Feature: UInt16, CaseIterable {
    case firmware = 0x0003
    case name = 0x0005
    case battery = 0x1000
    case unifiedBattery = 0x1004
    case changeHost = 0x1814
    case reprogControls = 0x1B04
    case wirelessStatus = 0x1D4B
    case smartShift = 0x2110
    case smartShiftTorque = 0x2111
    case hiResWheel = 0x2121
    case thumbWheel = 0x2150
    case adjustableDPI = 0x2201
}

/// Control IDs (CIDs) of the buttons Glide can take over through HID++.
enum ControlID {
    static let gesture: UInt16 = 0x00C3
    static let modeShift: UInt16 = 0x00C4
}

/// What the app shows about the connected mouse.
struct MouseState: Equatable {
    var name = "Logitech mouse"
    var productID = 0
    var transport = "Bluetooth"
    var firmware: String?
    var protocolVersion: String?
    var battery: Int?
    var charging = false
    var dpi: Int?
    var dpiDefault: Int?
    var dpiMin = 200
    var dpiMax = 8000
    var dpiStep = 50
    var supportsDPI = false
    var supportsSmartShift = false
    /// Current wheel mode as the mouse reports it (the button behind the wheel flips it).
    var freeSpin: Bool?
    /// Speed at which SmartShift lets the wheel spin free; 255 means never.
    var smartShiftThreshold: Int?
    var smartShiftDefault: Int?
    var ratchetsPerRotation: Int?
    var hiResMultiplier: Int?
    var hasGestureButton = false
    var hasModeShiftButton = false
    var hasThumbWheel = false
    var host: Int?
    var hostCount: Int?

    var wheelMode: WheelMode? {
        guard let freeSpin else { return nil }
        if freeSpin { return .freeSpin }
        guard let t = smartShiftThreshold else { return .ratchet }
        return t >= 50 ? .ratchet : .smartShift
    }
}

/// A Logitech mouse spoken to over HID++. All methods block and must run on the HID++ queue,
/// except `featureIndex(of:)`, which is safe anywhere.
final class LogitechMouse {
    let hid: HIDPPDevice
    private(set) var state: MouseState
    private let featureLock = UnfairLock()
    private var features: [Feature: UInt8] = [:]

    /// What Glide last wrote, so unchanged settings aren't sent again.
    var appliedDPI: Int?
    var appliedWheel: (WheelMode, Int)?
    var appliedDiversion: [UInt16: (divert: Bool, rawXY: Bool)] = [:]
    var appliedPointerAcceleration: PointerAcceleration?

    init(hid: HIDPPDevice, name: String, productID: Int) {
        self.hid = hid
        state = MouseState(name: name, productID: productID)
    }

    func featureIndex(of feature: Feature) -> UInt8? {
        featureLock.withLock { features[feature] }
    }

    private func index(_ feature: Feature) throws -> UInt8 {
        guard let i = featureIndex(of: feature) else { throw HIDPPError.unsupported("\(feature)") }
        return i
    }

    func forgetApplied() {
        appliedDPI = nil
        appliedWheel = nil
        appliedDiversion = [:]
        appliedPointerAcceleration = nil
    }

    // MARK: - Discovery

    func initialize() throws {
        let version = try hid.ping()
        state.protocolVersion = "\(version.0).\(version.1)"
        var found: [Feature: UInt8] = [:]
        for feature in Feature.allCases {
            let i = try hid.featureIndex(feature.rawValue)
            if i != 0 { found[feature] = i }
        }
        featureLock.withLock { features = found }
        Log.info("HID++ \(state.protocolVersion ?? "?"), features: " + found.keys.sorted { $0.rawValue < $1.rawValue }.map { String(format: "%04x", $0.rawValue) }.joined(separator: " "))

        if let name = try? readName(), !name.isEmpty { state.name = name }
        state.firmware = try? readFirmware()
        try? readBattery()
        try? readDPI()
        try? readWheel()
        try? readHiRes()
        try? readControls()
        try? readHost()
        state.hasThumbWheel = found[.thumbWheel] != nil
    }

    private func readName() throws -> String {
        let i = try index(.name)
        let length = Int(try hid.call(i, 0)[0])
        var bytes: [UInt8] = []
        while bytes.count < length {
            let chunk = try hid.call(i, 1, [UInt8(bytes.count)])
            bytes += chunk.prefix(length - bytes.count)
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
    }

    private func readFirmware() throws -> String? {
        let i = try index(.firmware)
        let count = Int(try hid.call(i, 0)[0])
        for entity in 0..<count {
            let r = try hid.call(i, 1, [UInt8(entity)])
            guard r[0] == 0 else { continue } // 0 = main application
            let prefix = String(decoding: r[1...3], as: UTF8.self)
            return String(format: "%@%02x.%02x_%04x", prefix, r[4], r[5], Int(r[6]) << 8 | Int(r[7]))
        }
        return nil
    }

    func readBattery() throws {
        if let i = featureIndex(of: .unifiedBattery) {
            applyBattery(try hid.call(i, 1), unified: true)
        } else if let i = featureIndex(of: .battery) {
            applyBattery(try hid.call(i, 0), unified: false)
        }
    }

    /// Battery status from a reply or a battery notification.
    func applyBattery(_ p: [UInt8], unified: Bool) {
        if unified {
            // [state of charge %, level flags, charging status, external power]
            state.battery = Int(p[0])
            state.charging = p[2] == 1 || p[2] == 2
        } else {
            // [level %, next level %, status]
            state.battery = Int(p[0])
            state.charging = (1...3).contains(p[2])
        }
    }

    private func readDPI() throws {
        let i = try index(.adjustableDPI)
        let list = try hid.call(i, 1, [0])
        var values: [Int] = []
        var step: Int?
        var k = 1
        while k + 1 < list.count {
            let v = Int(list[k]) << 8 | Int(list[k + 1])
            if v == 0 { break }
            if v & 0xE000 == 0xE000 { step = v & 0x1FFF } else { values.append(v) }
            k += 2
        }
        if let lo = values.min(), let hi = values.max() {
            state.dpiMin = lo
            state.dpiMax = hi
        }
        state.dpiStep = step ?? 50
        let current = try hid.call(i, 2, [0])
        state.dpi = Int(current[1]) << 8 | Int(current[2])
        let def = Int(current[3]) << 8 | Int(current[4])
        state.dpiDefault = def == 0 ? nil : def
        state.supportsDPI = true
    }

    func readWheel() throws {
        if let i = featureIndex(of: .smartShift) {
            // [wheel mode (1 free, 2 ratchet), auto-disengage threshold, default threshold]
            let r = try hid.call(i, 0)
            state.freeSpin = r[0] == 1
            state.smartShiftThreshold = Int(r[1])
            state.smartShiftDefault = Int(r[2])
            state.supportsSmartShift = true
        } else if let i = featureIndex(of: .smartShiftTorque) {
            let caps = try hid.call(i, 0)
            let r = try hid.call(i, 1)
            state.freeSpin = r[0] == 1
            state.smartShiftThreshold = Int(r[1])
            state.smartShiftDefault = Int(caps[1])
            state.supportsSmartShift = true
        }
    }

    private func readHiRes() throws {
        let i = try index(.hiResWheel)
        let caps = try hid.call(i, 0)
        state.hiResMultiplier = Int(caps[0])
        state.ratchetsPerRotation = Int(caps[2])
        // Glide reads the wheel as normal HID. If another app left it diverted to HID++
        // (where macOS can't see it) or in high-resolution mode (15x too fast), reset it.
        let mode = try hid.call(i, 1)[0]
        if mode & 0x03 != 0 {
            Log.info(String(format: "wheel was left in mode 0x%02x by other software; resetting to normal", mode))
            _ = try hid.call(i, 2, [mode & ~0x03])
        }
    }

    private func readControls() throws {
        let i = try index(.reprogControls)
        let count = Int(try hid.call(i, 0)[0])
        for n in 0..<count {
            let r = try hid.call(i, 1, [UInt8(n)])
            let cid = UInt16(r[0]) << 8 | UInt16(r[1])
            let divertable = r[4] & 0x20 != 0
            if cid == ControlID.gesture, divertable { state.hasGestureButton = true }
            if cid == ControlID.modeShift, divertable { state.hasModeShiftButton = true }
        }
    }

    private func readHost() throws {
        let i = try index(.changeHost)
        let r = try hid.call(i, 0)
        state.hostCount = Int(r[0])
        state.host = Int(r[1]) + 1
    }

    // MARK: - Settings

    func setDPI(_ dpi: Int) throws {
        let i = try index(.adjustableDPI)
        let value = min(max(dpi, state.dpiMin), state.dpiMax)
        _ = try hid.call(i, 3, [0, UInt8(value >> 8), UInt8(value & 0xFF)])
        state.dpi = value
        appliedDPI = dpi
        Log.info("DPI set to \(value)")
    }

    func setWheel(_ mode: WheelMode, threshold: Int) throws {
        let wheelMode: UInt8 = mode == .freeSpin ? 1 : 2
        let disengage: UInt8 = switch mode {
        case .ratchet: 255
        case .smartShift: UInt8(min(max(threshold, 1), 49))
        case .freeSpin: 0 // 0 = leave the SmartShift threshold as it is
        }
        if let i = featureIndex(of: .smartShift) {
            _ = try hid.call(i, 1, [wheelMode, disengage, 0])
        } else if let i = featureIndex(of: .smartShiftTorque) {
            _ = try hid.call(i, 2, [wheelMode, disengage, 0])
        } else {
            throw HIDPPError.unsupported("SmartShift")
        }
        appliedWheel = (mode, threshold)
        try? readWheel()
        Log.info("wheel set to \(mode.rawValue), threshold \(disengage)")
    }

    /// Flips between ratchet and free-spin, keeping the SmartShift threshold.
    func toggleWheelMode() throws {
        try readWheel()
        let toFree = !(state.freeSpin ?? false)
        if let i = featureIndex(of: .smartShift) {
            _ = try hid.call(i, 1, [toFree ? 1 : 2, 0, 0])
        } else if let i = featureIndex(of: .smartShiftTorque) {
            _ = try hid.call(i, 2, [toFree ? 1 : 2, 0, 0])
        }
        try readWheel()
    }

    /// Takes a button over (divert) so its presses come to Glide instead of doing their
    /// built-in job. rawXY also sends pointer movement to Glide while the button is held,
    /// which is what makes hold-and-move gestures possible.
    func setDiversion(_ cid: UInt16, divert: Bool, rawXY: Bool) throws {
        if let last = appliedDiversion[cid], last.divert == divert, last.rawXY == rawXY { return }
        let i = try index(.reprogControls)
        // flags: divert (bit 0) + valid (bit 1), rawXY (bit 4) + valid (bit 5)
        let flags: UInt8 = (divert ? 0x01 : 0) | 0x02 | (rawXY ? 0x10 : 0) | 0x20
        _ = try hid.call(i, 3, [UInt8(cid >> 8), UInt8(cid & 0xFF), flags, 0, 0])
        appliedDiversion[cid] = (divert, rawXY)
        Log.info(String(format: "button %04x: %@%@", cid, divert ? "taken over" : "back to normal", rawXY ? " with gestures" : ""))
    }
}
