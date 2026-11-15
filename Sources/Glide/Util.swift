import Foundation
import os

/// Marks events Glide posts itself, so its own event tap lets them through untouched.
let kGlideEventMarker: Int64 = 0x474C_4944 // "GLID"

final class UnfairLock: @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<os_unfair_lock>

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(pointer)
        defer { os_unfair_lock_unlock(pointer) }
        return try body()
    }
}

/// Small rolling log at ~/Library/Logs/Glide.log, also sent to the unified log.
enum Log {
    private static let logger = Logger(subsystem: "local.peripherals.glide", category: "glide")
    private static let queue = DispatchQueue(label: "glide.log", qos: .utility)
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Glide.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    static var echo = false

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        let now = Date()
        queue.async {
            let line = "\(formatter.string(from: now))  \(message)\n"
            if echo { FileHandle.standardError.write(line.data(using: .utf8)!) }
            append(line)
        }
    }

    private static func append(_ line: String) {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512_000 {
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    }
}

/// A thread with its own run loop. The event tap and the HID manager live here so that
/// scrolling never waits on the UI.
final class RunLoopThread: Thread {
    private(set) var runLoop: CFRunLoop!
    private let ready = DispatchSemaphore(value: 0)

    init(name: String) {
        super.init()
        self.name = name
        qualityOfService = .userInteractive
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A timer that never fires keeps the run loop alive while it has no other sources.
        let keepAlive = CFRunLoopTimerCreateWithHandler(nil, Date.distantFuture.timeIntervalSinceReferenceDate, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(runLoop, keepAlive, .commonModes)
        ready.signal()
        CFRunLoopRun()
    }

    func startAndWait() {
        start()
        ready.wait()
    }

    func async(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    func sync<T>(_ block: @escaping () -> T) -> T {
        if Thread.current == self { return block() }
        var result: T?
        let done = DispatchSemaphore(value: 0)
        async {
            result = block()
            done.signal()
        }
        done.wait()
        return result!
    }
}

extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}
