import AppKit
import CoreVideo
import GlideCore

/// Plays scroll glides out as pixel scroll events, one per display frame.
///
/// Wheel clicks arrive on the driver thread; frames tick on the display link's own thread.
/// Events go out in step with the screen refresh (120 Hz on ProMotion), which is what
/// keeps the motion free of judder.
final class ScrollOutput {
    private let lock = UnfairLock()
    private var axes = [AxisMotion(), AxisMotion()] // 0 vertical, 1 horizontal
    private var feels = [ScrollFeel](repeating: ScrollFeel(pixelsPerClick: 100, smoothness: 0.07, acceleration: 0), count: 2)
    private var wantRunning = false
    private var lastHostTime: UInt64 = 0
    private var idleFrames = 0
    private var framePeriod = 1.0 / 60
    private var startHostTime: UInt64 = 0

    private var link: CVDisplayLink?
    private let linkQueue = DispatchQueue(label: "glide.displaylink")
    private let hostFrequency = CVGetHostClockFrequency()

    /// Optional tap for the self-test: sees every delta that is posted.
    var observer: ((Int, Int) -> Void)?

    init() {
        var created: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&created)
        guard let created else {
            Log.info("could not create a display link; smooth scrolling falls back to instant")
            return
        }
        link = created
        CVDisplayLinkSetOutputCallback(created, { _, now, outputTime, _, _, context in
            Unmanaged<ScrollOutput>.fromOpaque(context!).takeUnretainedValue().frame(now: now.pointee, output: outputTime.pointee)
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Adds signed wheel clicks to an axis (0 vertical, 1 horizontal).
    func push(axis: Int, clicks: Double, feel: ScrollFeel, at time: Double) {
        guard clicks != 0 else { return }
        if feel.smoothness <= 0 || link == nil {
            var instant = feel
            instant.smoothness = 0
            let delta: Int = lock.withLock {
                axes[axis].push(clicks: clicks, feel: instant, at: time)
                return axes[axis].advance(dt: 0, feel: instant)
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
            startHostTime = mach_absolute_time()
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

    private func frame(now: CVTimeStamp, output time: CVTimeStamp) {
        var dy = 0, dx = 0, stop = false
        lock.withLock {
            var dt: Double
            if lastHostTime == 0 || time.hostTime <= lastHostTime {
                // First tick after starting: cover the real time since the first frame went out.
                dt = now.hostTime > startHostTime && startHostTime != 0
                    ? Double(now.hostTime - startHostTime) / hostFrequency
                    : framePeriod
            } else {
                // Steady state: step by the spacing of the frames on screen.
                dt = Double(time.hostTime - lastHostTime) / hostFrequency
            }
            lastHostTime = time.hostTime
            dt = min(max(dt, 1.0 / 500), 1.0 / 20)
            framePeriod = dt
            dy = axes[0].advance(dt: dt, feel: feels[0])
            dx = axes[1].advance(dt: dt, feel: feels[1])
            if axes[0].isIdle && axes[1].isIdle {
                idleFrames += 1
                if idleFrames > 45, wantRunning {
                    wantRunning = false
                    stop = true
                }
            } else {
                idleFrames = 0
            }
        }
        post(dy: dy, dx: dx)
        if stop { linkQueue.async { self.syncLink() } }
    }

    /// Starts or stops the display link to match `wantRunning`. Runs on linkQueue only,
    /// so start and stop can never race each other.
    private func syncLink() {
        guard let link else { return }
        let want = lock.withLock { wantRunning }
        let running = CVDisplayLinkIsRunning(link)
        if want, !running {
            // Tick with the display the pointer is on.
            if let location = CGEvent(source: nil)?.location {
                var display: CGDirectDisplayID = 0
                var count: UInt32 = 0
                if CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count > 0 {
                    CVDisplayLinkSetCurrentCGDisplay(link, display)
                }
            }
            CVDisplayLinkStart(link)
        } else if !want, running {
            CVDisplayLinkStop(link)
        }
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
