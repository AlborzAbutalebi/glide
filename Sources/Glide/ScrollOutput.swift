import AppKit
import CoreVideo
import GlideCore

/// Plays scroll glides out as pixel scroll events, one per display frame.
///
/// Wheel clicks arrive on the driver thread; frames tick on the display link's own thread.
/// Events go out in step with the screen refresh (120 Hz on ProMotion), which is what
/// keeps the motion free of judder.
///
/// A display link can stop delivering frames (display sleep, a monitor change, a failed
/// start). Glide would then swallow every wheel click and scroll nothing, so a backup
/// timer runs alongside it during each glide: if no frame has gone out for 50 ms it
/// produces the frames itself, and the display link is rebuilt.
final class ScrollOutput {
    private let lock = UnfairLock()
    private var axes = [AxisMotion(), AxisMotion()] // 0 vertical, 1 horizontal
    private var feels = [ScrollFeel](repeating: ScrollFeel(pixelsPerClick: 100, smoothness: 0.07, acceleration: 0), count: 2)
    private var wantRunning = false
    /// Output time of the last display-link frame (0 = next link frame is the first).
    private var lastHostTime: UInt64 = 0
    /// When any frame last went out (host time, the same clock as mach_absolute_time).
    private var lastFrameTime: UInt64 = 0
    private var idleFrames = 0
    private var framePeriod = 1.0 / 60
    private var stallReported = false

    private var link: CVDisplayLink? // linkQueue only
    private var backup: DispatchSourceTimer? // linkQueue only
    private let linkQueue = DispatchQueue(label: "glide.displaylink")
    private let backupQueue = DispatchQueue(label: "glide.backupframes", qos: .userInteractive)
    private let hostFrequency = CVGetHostClockFrequency()
    private static let stallThreshold = 0.05

    /// Optional tap for the self-test: sees every delta that is posted.
    var observer: ((Int, Int) -> Void)?
    /// Self-test only: pretend the display link has stopped delivering frames.
    var simulateStalledLink = false

    init() {
        linkQueue.sync { link = makeLink() }
    }

    private func makeLink() -> CVDisplayLink? {
        var created: CVDisplayLink?
        let result = CVDisplayLinkCreateWithActiveCGDisplays(&created)
        guard let created, result == kCVReturnSuccess else {
            Log.info("could not create a display link (\(result)); the backup timer will pace scrolling")
            return nil
        }
        CVDisplayLinkSetOutputCallback(created, { _, now, outputTime, _, _, context in
            Unmanaged<ScrollOutput>.fromOpaque(context!).takeUnretainedValue().linkFrame(now: now.pointee, output: outputTime.pointee)
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        return created
    }

    /// Adds signed wheel clicks to an axis (0 vertical, 1 horizontal).
    func push(axis: Int, clicks: Double, feel: ScrollFeel, at time: Double) {
        guard clicks != 0 else { return }
        if feel.smoothness <= 0 {
            let delta: Int = lock.withLock {
                axes[axis].push(clicks: clicks, feel: feel, at: time)
                return axes[axis].advance(dt: 0, feel: feel)
            }
            post(dy: axis == 0 ? delta : 0, dx: axis == 1 ? delta : 0)
            return
        }
        let (start, first): (Bool, Int) = lock.withLock {
            axes[axis].push(clicks: clicks, feel: feel, at: time)
            feels[axis] = feel
            idleFrames = 0
            if wantRunning { return (false, 0) }
            wantRunning = true
            lastHostTime = 0
            lastFrameTime = mach_absolute_time()
            // Don't wait for the display link to spin up (one or two frames): move the
            // first frame's worth right away, so the page responds the instant you click.
            return (true, axes[axis].advance(dt: framePeriod, feel: feel))
        }
        if first != 0 { post(dy: axis == 0 ? first : 0, dx: axis == 1 ? first : 0) }
        if start { linkQueue.async { self.syncLink() } }
    }

    /// Stops any glide in progress (used when Glide is paused).
    func stopAll() {
        lock.withLock {
            axes[0].stop()
            axes[1].stop()
        }
    }

    var isIdle: Bool { lock.withLock { axes[0].isIdle && axes[1].isIdle } }

    /// The screens changed or the Mac woke up: start from a fresh display link.
    func displaysChanged() {
        linkQueue.async { self.rebuildLink(reason: "the displays changed") }
    }

    // MARK: - Frames

    private func linkFrame(now: CVTimeStamp, output: CVTimeStamp) {
        if simulateStalledLink { return }
        let result: (Int, Int, Bool) = lock.withLock {
            var dt: Double
            if lastHostTime == 0 || output.hostTime <= lastHostTime {
                // First link frame after a start or a backup frame: cover the real time since.
                dt = now.hostTime > lastFrameTime ? Double(now.hostTime - lastFrameTime) / hostFrequency : framePeriod
            } else {
                // Steady state: step by the spacing of the frames on screen.
                dt = Double(output.hostTime - lastHostTime) / hostFrequency
                framePeriod = min(max(dt, 1.0 / 240), 1.0 / 30)
            }
            lastHostTime = output.hostTime
            stallReported = false
            return step(dt, at: now.hostTime)
        }
        finish(result)
    }

    private func backupTick() {
        let now = mach_absolute_time()
        var result: (Int, Int, Bool)?
        var rebuild = false
        lock.withLock {
            guard wantRunning, now > lastFrameTime else { return }
            let since = Double(now - lastFrameTime) / hostFrequency
            // Wait 50 ms before deciding the display link has stalled; once it has, keep
            // up a full frame rate (about 120 Hz) until the link delivers frames again.
            guard since > (stallReported ? 0.007 : Self.stallThreshold) else { return }
            if !stallReported {
                stallReported = true
                rebuild = true
            }
            lastHostTime = 0 // the link's next frame measures from this one
            result = step(since, at: now)
        }
        if rebuild { linkQueue.async { self.rebuildLink(reason: "it stopped delivering frames") } }
        if let result { finish(result) }
    }

    /// Advances both axes. Call with the lock held.
    private func step(_ rawDt: Double, at time: UInt64) -> (Int, Int, Bool) {
        let dt = min(max(rawDt, 1.0 / 500), 1.0 / 20)
        lastFrameTime = time
        let dy = axes[0].advance(dt: dt, feel: feels[0])
        let dx = axes[1].advance(dt: dt, feel: feels[1])
        var stop = false
        if axes[0].isIdle && axes[1].isIdle {
            idleFrames += 1
            if idleFrames > 45, wantRunning {
                wantRunning = false
                stop = true
            }
        } else {
            idleFrames = 0
        }
        return (dy, dx, stop)
    }

    private func finish(_ result: (Int, Int, Bool)) {
        post(dy: result.0, dx: result.1)
        if result.2 { linkQueue.async { self.syncLink() } }
    }

    // MARK: - Display link and backup timer (linkQueue)

    /// Starts or stops the display link and the backup timer to match `wantRunning`.
    /// Runs on linkQueue only, so starts and stops can never race each other.
    private func syncLink() {
        let want = lock.withLock { wantRunning }
        if want {
            if let link, !CVDisplayLinkIsRunning(link) {
                // Tick with the display the pointer is on.
                if let location = CGEvent(source: nil)?.location {
                    var display: CGDirectDisplayID = 0
                    var count: UInt32 = 0
                    if CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count > 0 {
                        CVDisplayLinkSetCurrentCGDisplay(link, display)
                    }
                }
                let result = CVDisplayLinkStart(link)
                if result != kCVReturnSuccess { Log.info("display link did not start (\(result)); the backup timer takes over") }
            }
            if backup == nil {
                let timer = DispatchSource.makeTimerSource(queue: backupQueue)
                timer.schedule(deadline: .now() + .milliseconds(8), repeating: .milliseconds(8), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.backupTick() }
                timer.resume()
                backup = timer
            }
        } else {
            if let link, CVDisplayLinkIsRunning(link) { CVDisplayLinkStop(link) }
            backup?.cancel()
            backup = nil
        }
    }

    private func rebuildLink(reason: String) {
        Log.info("rebuilding the display link because \(reason)")
        if let old = link, CVDisplayLinkIsRunning(old) { CVDisplayLinkStop(old) }
        link = makeLink()
        lock.withLock { lastHostTime = 0 }
        syncLink()
    }

    private func post(dy: Int, dx: Int) {
        guard dy != 0 || dx != 0 else { return }
        observer?(dy, dx)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(clamping: dy), wheel2: Int32(clamping: dx), wheel3: 0) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: kGlideEventMarker)
        if let location = CGEvent(source: nil)?.location { event.location = location }
        event.flags = []
        event.post(tap: .cgSessionEventTap)
    }
}
