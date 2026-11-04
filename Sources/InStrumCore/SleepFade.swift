import Foundation

/// The sleep timer's clock (spec §3): a countdown whose last minutes fade the sound to silence and dim the world toward
/// night. At its end the world rests there, silent and dim with the timer Off, until a key, a pedal or a click wakes it.
///
/// Every reading takes the time (seconds on one clock; the app's is `systemUptime`), so the ticker, a mid-fade autosave
/// and the tests all read the same curves. Nothing here is saved.
/// - **The fade** runs over the last `fadeSeconds`, or all of a shorter timer. Over its progress p (0 → 1) the gain
///   follows `curve(p)`, from 1 down to `endGain` (−60 dB), and the dim sin²(πp/2), from 0 up to 1.
/// - **The end:** the gain is 0, the dim 1, and `remaining` is nil.
/// - **Waking** ends the countdown and glides the gain and the dim in a straight line back to 1 and 0 over
///   `wakeSeconds`, from wherever they were. A glide under way carries on through another wake, Off or a new timer.
///
/// The app's ticker passes its last key, pedal or click to `wake(at:)`, sends `gain(at:)` to the engine's `sleepGain`,
/// `dim(at:)` to `SceneControls.sleepDim` and `remaining(at:)` to the moon, and stops once `isOff(at:)`.
public struct SleepFade: Equatable {
    /// The moon's timers, in minutes.
    public static let choices = [15, 30, 45, 60, 90]
    /// The fade covers a timer's last 10 minutes, or all of a shorter one.
    public static let fadeSeconds = 600.0
    /// Waking brings the sound and the light back over 3 s.
    public static let wakeSeconds = 3.0
    /// The fade's last gain, −60 dB. Silence follows it.
    public static let endGain: Float = 0.001

    /// A countdown, from its choosing until a wake. It stays through the rest after its end.
    private struct Countdown: Equatable { var fadeStart, end: Double }
    /// A wake under way: when it began, and the gain and the dim it glides back from.
    private struct Glide: Equatable { var start: Double; var gain: Float; var dim: Double }

    private var countdown: Countdown?
    private var glide: Glide?

    public init() {}

    /// The fade's gain at progress p (clamped to 0…1): 0.001 + 0.999·cos²(πp/2), so 1 at its start, 0.5005 half way
    /// and `endGain` at its end.
    public static func curve(_ p: Double) -> Float {
        let e = Double(endGain), c = cos(Double.pi * min(1, max(0, p)) / 2)
        return Float(e + (1 - e) * c * c)
    }

    /// The fade's dim at progress p (clamped to 0…1): sin²(πp/2), so the light falls with the sound.
    static func dimCurve(_ p: Double) -> Double {
        let s = sin(Double.pi * min(1, max(0, p)) / 2)
        return s * s
    }

    // MARK: - Choosing

    /// Starts the countdown, or restarts it at a new length. A fading or resting world wakes first, gliding back over
    /// 3 s, and a glide already under way carries on. Zero minutes or fewer turns the timer off.
    public mutating func start(minutes: Int, at t: Double) {
        guard minutes > 0 else { turnOff(at: t); return }
        if isFading(at: t) { wake(at: t) }
        settle(at: t)
        let length = Double(minutes) * 60, end = t + length
        countdown = Countdown(fadeStart: end - min(Self.fadeSeconds, length), end: end)
    }

    /// Wakes a fading or resting world: the countdown ends (the timer is Off), and the gain and the dim glide back to
    /// 1 and 0 over `wakeSeconds`. Returns true if it woke the world.
    ///
    /// It is ignored before the fade, judged by its own time, so the app can pass its last activity on every tick and
    /// playing from before the fade never cancels it. It is ignored while a glide is under way, too.
    @discardableResult
    public mutating func wake(at t: Double) -> Bool {
        guard isFading(at: t) else { return false }
        glide = Glide(start: t, gain: gain(at: t), dim: dim(at: t))
        countdown = nil
        return true
    }

    /// Turns the timer Off. A fading or resting world wakes, gliding back over 3 s, and a countdown that hasn't begun
    /// to fade just stops. A glide already under way carries on.
    public mutating func turnOff(at t: Double) {
        guard !wake(at: t) else { return }
        countdown = nil
        settle(at: t)
    }

    /// Forgets a finished glide, so a timer that is off again equals a new one.
    private mutating func settle(at t: Double) {
        if let w = glide, t >= w.start + Self.wakeSeconds { glide = nil }
    }

    // MARK: - Readings

    /// The gain the sound plays at: 1, then down the fade's curve, 0 from the end, and back up while waking.
    public func gain(at t: Double) -> Float {
        var g: Float = 1
        if let c = countdown, t >= c.fadeStart { g = t >= c.end ? 0 : Self.curve(progress(c, t)) }
        if let w = glide, t < w.start + Self.wakeSeconds {
            g = min(g, Float(Double(w.gain) + (1 - Double(w.gain)) * waking(w, t)))
        }
        return g
    }

    /// How far the world has dimmed toward night (0…1): 0, then up with the fade, 1 from the end, and back down
    /// while waking.
    public func dim(at t: Double) -> Double {
        var d = 0.0
        if let c = countdown, t >= c.fadeStart { d = t >= c.end ? 1 : Self.dimCurve(progress(c, t)) }
        if let w = glide, t < w.start + Self.wakeSeconds { d = max(d, w.dim * (1 - waking(w, t))) }
        return d
    }

    /// The seconds left on the timer, or nil unless it is counting down: before it is set, from its end, and once it
    /// is woken or off.
    public func remaining(at t: Double) -> Double? {
        guard let c = countdown, t < c.end else { return nil }
        return c.end - t
    }

    /// True during the fade, and while the world rests dim and silent after it.
    public func isFading(at t: Double) -> Bool {
        guard let c = countdown else { return false }
        return t >= c.fadeStart
    }

    /// True once there is nothing left to do: no countdown, no rest and no glide under way, so the gain stays 1 and the
    /// dim 0. The app's ticker stops here.
    public func isOff(at t: Double) -> Bool {
        countdown == nil && (glide.map { t >= $0.start + Self.wakeSeconds } ?? true)
    }

    /// The fade's progress, 0 at its start and 1 at the end.
    private func progress(_ c: Countdown, _ t: Double) -> Double { (t - c.fadeStart) / (c.end - c.fadeStart) }

    /// How far a glide has come, 0 when it begins and 1 after `wakeSeconds`.
    private func waking(_ w: Glide, _ t: Double) -> Double { min(1, max(0, (t - w.start) / Self.wakeSeconds)) }
}
