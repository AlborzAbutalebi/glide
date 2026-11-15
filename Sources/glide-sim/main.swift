import Foundation
import GlideCore

// Offline check of the scroll physics: feeds scripted wheel clicks through AxisMotion
// at a fixed frame rate and reports distance, timing and smoothness.
// Usage: glide-sim [csv-output-path]

let fps = 120.0
let dt = 1 / fps

struct Result {
    var name: String
    var expected: Double
    var frames: [(t: Double, d: Int)] = []
    var total: Int { frames.reduce(0) { $0 + $1.d } }
}

func run(_ name: String, feel: ScrollFeel, clicks: [(t: Double, n: Double)], expected: Double, duration: Double = 1.5) -> Result {
    var axis = AxisMotion()
    var r = Result(name: name, expected: expected)
    var queue = clicks
    var t = 0.0
    while t < duration {
        while let c = queue.first, c.t <= t + 1e-9 {
            axis.push(clicks: c.n, feel: feel, at: c.t)
            queue.removeFirst()
        }
        r.frames.append((t, axis.advance(dt: dt, feel: feel)))
        t += dt
    }
    return r
}

var failures = 0
func check(_ ok: Bool, _ msg: String) {
    print(ok ? "  ok   " : "  FAIL ", msg)
    if !ok { failures += 1 }
}

let classic = ScrollFeel(pixelsPerClick: 100, smoothness: 0.07, acceleration: 0)
var results: [Result] = []

// 1. One click.
let one = run("single click", feel: classic, clicks: [(0, -1)], expected: -100)
results.append(one)
print("single click (100pt, 70ms):")
check(one.total == -100, "total \(one.total) == -100")
var cumulative = 0, t90 = 0.0, t99 = 0.0, tDone = 0.0
for f in one.frames {
    cumulative += f.d
    if t90 == 0, abs(cumulative) >= 90 { t90 = f.t }
    if t99 == 0, abs(cumulative) >= 99 { t99 = f.t }
    if f.d != 0 { tDone = f.t }
}
check(one.frames.allSatisfy { $0.d <= 0 }, "never moves the wrong way")
print(String(format: "         90%% after %.0f ms, 99%% after %.0f ms, finished after %.0f ms, first frame %d pt", t90 * 1000, t99 * 1000, tDone * 1000, one.frames[0].d))
check(tDone < 0.45, "finishes within 450 ms")

// 2. Steady ratchet scrolling, 10 clicks/s for 1 s.
let steady = run("steady 10/s", feel: classic, clicks: (0..<10).map { (Double($0) * 0.1, -1) }, expected: -1000, duration: 2)
results.append(steady)
print("steady 10 clicks/s:")
check(steady.total == -1000, "total \(steady.total) == -1000 (linear: every click the same)")

// 3. Fast spin 40 clicks/s, no acceleration vs medium acceleration.
let spinClicks = (0..<40).map { (Double($0) * 0.025, -1.0) }
let spinLinear = run("spin 40/s linear", feel: classic, clicks: spinClicks, expected: -4000, duration: 2)
var accelFeel = classic; accelFeel.acceleration = 0.5
let spinAccel = run("spin 40/s accel 0.5", feel: accelFeel, clicks: spinClicks, expected: .nan, duration: 2)
results += [spinLinear, spinAccel]
print("fast spin 40 clicks/s:")
check(spinLinear.total == -4000, "linear total \(spinLinear.total) == -4000")
check(abs(spinAccel.total) > 4000, "acceleration scrolls further: \(spinAccel.total)")

// 4. Reversal: 4 clicks down, then 1 click up 60 ms later must turn around at once.
let rev = run("reversal", feel: classic, clicks: [(0, -1), (0.02, -1), (0.04, -1), (0.06, -1), (0.12, 1)], expected: .nan)
results.append(rev)
let afterRev = rev.frames.filter { $0.t > 0.12 + 1e-9 }
print("reversal:")
check((afterRev.first?.d ?? 0) > 0, "first frame after the up-click moves up (\(afterRev.first?.d ?? 0) pt)")
check(afterRev.allSatisfy { $0.d >= 0 }, "no leftover downward motion after reversing")

// 5. Instant mode emits everything on the click's frame.
let instant = run("instant", feel: ScrollFeel(pixelsPerClick: 100, smoothness: 0, acceleration: 0), clicks: [(0, -1)], expected: -100, duration: 0.1)
print("instant mode:")
check(instant.frames[0].d == -100 && instant.total == -100, "whole click on the first frame")

// 6. Fractional distances never drift: 37 clicks of 33.3 pt.
let frac = run("fractional", feel: ScrollFeel(pixelsPerClick: 33.3, smoothness: 0.09, acceleration: 0), clicks: (0..<37).map { (Double($0) * 0.07, 1) }, expected: 1232.1, duration: 4)
print("fractional distances:")
check(abs(Double(frac.total) - 1232.1) <= 1, "total \(frac.total) ≈ 1232.1")

if CommandLine.arguments.count > 1 {
    var csv = "scenario,time_ms,delta_pt\n"
    for r in results { for f in r.frames { csv += "\(r.name),\(Int(f.t * 1000)),\(f.d)\n" } }
    try? csv.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
}
print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
