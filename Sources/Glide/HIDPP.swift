import Foundation
import IOKit.hid

/// Logitech HID++ 2.0 over a directly connected (Bluetooth) device.
///
/// Message layout (long report, 20 bytes):
///   [0x11] [device index] [feature index] [function << 4 | software id] [16 bytes of parameters]
/// A Bluetooth device answers on device index 0xFF. Replies echo the first four bytes;
/// notifications from the device carry software id 0. Errors come back with feature
/// index 0xFF: [0x11, 0xFF, 0xFF, original feature index, original function, error code].
enum HIDPPError: Error, CustomStringConvertible {
    case timeout
    case send(IOReturn)
    case device(UInt8)
    case unsupported(String)

    var description: String {
        switch self {
        case .timeout: "no reply from the mouse"
        case .send(let r): String(format: "send failed (0x%08x)", r)
        case .device(let code): "the mouse refused the request (error \(code))"
        case .unsupported(let what): "\(what) is not supported by this mouse"
        }
    }
}

final class HIDPPDevice {
    let device: IOHIDDevice
    let deviceIndex: UInt8 = 0xFF
    private static let softwareID: UInt8 = 0x0B
    private static let reportID: UInt8 = 0x11
    private static let reportLength = 20

    /// Called on the driver thread for unsolicited messages: feature index, event number, parameters.
    var onNotification: ((UInt8, UInt8, [UInt8]) -> Void)?

    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let lock = NSLock()
    private var expected: (feature: UInt8, function: UInt8)?
    private var reply: [UInt8]?
    private let replied = DispatchSemaphore(value: 0)
    private var attached = false

    init(device: IOHIDDevice) {
        self.device = device
    }

    deinit {
        buffer.deallocate()
    }

    /// Starts receiving input reports. Call on the thread whose run loop the device is scheduled on.
    func attach() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, _, report, length in
            guard let context else { return }
            let me = Unmanaged<HIDPPDevice>.fromOpaque(context).takeUnretainedValue()
            me.received(Array(UnsafeBufferPointer(start: report, count: length)))
        }, context)
        attached = true
    }

    func detach() {
        guard attached else { return }
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
        attached = false
        lock.lock()
        expected = nil
        lock.unlock()
        replied.signal()
    }

    private func received(_ bytes: [UInt8]) {
        guard bytes.count >= 4, bytes[0] == 0x11 || bytes[0] == 0x10, bytes[1] == deviceIndex else { return }
        let feature = bytes[2], function = bytes[3]
        lock.lock()
        if let want = expected {
            let isReply = feature == want.feature && function == want.function
            let isError = (feature == 0xFF || feature == 0x8F) && bytes.count >= 6 && bytes[3] == want.feature && bytes[4] == want.function
            if isReply || isError {
                reply = bytes
                expected = nil
                lock.unlock()
                replied.signal()
                return
            }
        }
        lock.unlock()
        if function & 0x0F == 0, feature != 0xFF {
            onNotification?(feature, function >> 4, Array(bytes.dropFirst(4)))
        }
    }

    /// Sends a request and waits for its reply. Blocking: call from the HID++ queue only.
    func call(_ feature: UInt8, _ function: UInt8, _ params: [UInt8] = [], timeout: TimeInterval = 1.0) throws -> [UInt8] {
        do {
            return try attempt(feature, function, params, timeout: timeout)
        } catch HIDPPError.timeout {
            return try attempt(feature, function, params, timeout: timeout)
        }
    }

    private func attempt(_ feature: UInt8, _ function: UInt8, _ params: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        let fn = (function << 4) | Self.softwareID
        lock.lock()
        expected = (feature, fn)
        reply = nil
        lock.unlock()

        var report = [Self.reportID, deviceIndex, feature, fn] + params.prefix(16)
        report += [UInt8](repeating: 0, count: Self.reportLength - report.count)
        let sent = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(Self.reportID), report, report.count)
        guard sent == kIOReturnSuccess else {
            lock.lock(); expected = nil; lock.unlock()
            throw HIDPPError.send(sent)
        }

        let deadline = DispatchTime.now() + timeout
        while true {
            let waited = replied.wait(timeout: deadline)
            lock.lock()
            let got = reply
            if got != nil || waited == .timedOut { expected = nil }
            lock.unlock()
            if let got {
                if got[2] == 0xFF || got[2] == 0x8F { throw HIDPPError.device(got.count > 5 ? got[5] : 0) }
                return Array(got.dropFirst(4))
            }
            if waited == .timedOut { throw HIDPPError.timeout }
            // A stray wake-up from an earlier, timed-out request: keep waiting.
        }
    }

    /// Looks up the index of a feature (0 means the device doesn't have it).
    func featureIndex(_ id: UInt16) throws -> UInt8 {
        let r = try call(0x00, 0x0, [UInt8(id >> 8), UInt8(id & 0xFF)])
        return r[0]
    }

    /// Returns the HID++ protocol version, e.g. (4, 5).
    func ping() throws -> (Int, Int) {
        let r = try call(0x00, 0x1, [0, 0, 0x5A])
        return (Int(r[0]), Int(r[1]))
    }
}
