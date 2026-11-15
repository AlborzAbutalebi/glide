import Foundation

/// How one wheel click should feel.
public struct ScrollFeel: Equatable, Sendable {
    /// Distance of one wheel click, in points.
    public var pixelsPerClick: Double
    /// Glide time constant in seconds. 0 means no animation: each click jumps at once.
    public var smoothness: Double
    /// 0 keeps every click the same distance (a classic wheel). Higher values scroll
    /// further per click when the wheel is spun quickly.
    public var acceleration: Double

    public init(pixelsPerClick: Double, smoothness: Double, acceleration: Double) {
        self.pixelsPerClick = pixelsPerClick
        self.smoothness = smoothness
        self.acceleration = acceleration
    }
}

/// One scroll axis. Wheel clicks move a target; `advance` glides towards it and hands
/// back whole points to send, carrying the sub-point remainder so nothing is lost.
public struct AxisMotion: Sendable {
    public private(set) var target: Double = 0
    public private(set) var position: Double = 0
    private var emitted: Int = 0
    private var lastClickTime: Double = -1_000
    private var clickRate: Double = 0

    public init() {}

    public var isIdle: Bool { target == position }
    public var remaining: Double { target - position }

    /// Adds signed wheel clicks at `time` (seconds). Returns the distance added.
    @discardableResult
    public mutating func push(clicks: Double, feel: ScrollFeel, at time: Double) -> Double {
        guard clicks != 0 else { return 0 }
        let left = target - position
        var reversed = false
        if left != 0, (left > 0) != (clicks > 0) {
            // Turn around now instead of finishing the old glide first.
            target = position
            reversed = true
        }
        let gap = time - lastClickTime
        if reversed || gap > 0.3 {
            clickRate = 0
        } else {
            let instant = abs(clicks) / max(gap, 0.006)
            clickRate = clickRate == 0 ? instant : clickRate * 0.55 + instant * 0.45
        }
        lastClickTime = time
        let distance = clicks * feel.pixelsPerClick * AxisMotion.boost(rate: clickRate, acceleration: feel.acceleration)
        target += distance
        return distance
    }

    /// Distance multiplier for a given spin speed (clicks per second).
    /// Slow, deliberate scrolling (under 8 clicks/s) is never boosted.
    public static func boost(rate: Double, acceleration: Double) -> Double {
        guard acceleration > 0 else { return 1 }
        let over = min(max(0, rate - 8) / 12, 5)
        return 1 + acceleration * over
    }

    /// Moves the glide forward by `dt` seconds. Returns the whole points to send now.
    public mutating func advance(dt: Double, feel: ScrollFeel) -> Int {
        let left = target - position
        if left != 0 {
            if feel.smoothness <= 0 {
                position = target
            } else {
                var move = left * (1 - exp(-dt / feel.smoothness))
                // A minimum speed so the last point or two never crawls.
                let floor = 80 * dt
                if abs(move) < floor { move = left > 0 ? min(floor, left) : max(-floor, left) }
                if abs(left - move) < 0.02 { position = target } else { position += move }
            }
        }
        let whole = Int(position.rounded())
        let out = whole - emitted
        emitted = whole
        if position == target {
            // Re-base so the numbers never grow; the sub-point remainder is kept.
            let shift = Double(emitted)
            position -= shift
            target -= shift
            emitted = 0
        }
        return out
    }

    /// Drops whatever is left of the current glide.
    public mutating func stop() { target = position }
}
