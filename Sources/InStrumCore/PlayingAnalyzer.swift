import Foundation

public enum ChordQuality: Equatable { case none, major, minor, tense, open }

/// Understands how you're playing over time and publishes it as `playing.*` inputs.
public struct PlayingAnalyzer {
    static let busyWindow = 2.0
    static let busyFull = 24.0
    static let silenceFull = 8.0
    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    public private(set) var chord: ChordQuality = .none
    public private(set) var keyRoot: Int?
    public private(set) var keyIsMinor = false
    /// How sure the key estimate is: its correlation minus the best one on any other root (the parallel mode on the
    /// same root doesn't count against it: the tonic is the same). 0 before 8 notes.
    public private(set) var keyConfidence = 0.0

    private var held: Set<UInt8> = []
    private var strikes: [(t: Double, v: Double)] = []
    private var melody: [UInt8] = []
    private var recent: [UInt8] = []
    private var histogram = [Double](repeating: 0, count: 12)
    private var noteCount = 0
    private var lastNoteOn: Double?

    public init() {}

    public mutating func handle(_ e: PerformanceEvent, at t: Double) {
        switch e {
        case let .noteOn(note, velocity):
            let isTop = held.allSatisfy { note >= $0 }
            held.insert(note)
            strikes.append((t, Double(velocity)))
            strikes.removeAll { t - $0.t > Self.busyWindow }
            if isTop { melody.append(note); if melody.count > 7 { melody.removeFirst() } }
            recent.append(note); if recent.count > 8 { recent.removeFirst() }
            for i in 0..<12 { histogram[i] *= 0.98 }
            histogram[Int(note % 12)] += 1
            noteCount += 1
            lastNoteOn = t
            if noteCount >= 8 { estimateKey() }
            chord = Self.classify(held)
        case let .noteOff(note):
            held.remove(note)
            chord = Self.classify(held)
        case .allNotesOff:
            held.removeAll()
            chord = .none
        default:
            break
        }
    }

    public mutating func publish(to hub: InputHub, at t: Double) {
        hub.set(.chordMajor, chord == .major ? 1 : 0, at: t)
        hub.set(.chordMinor, chord == .minor ? 1 : 0, at: t)
        hub.set(.chordTense, chord == .tense ? 1 : 0, at: t)
        hub.set(.direction, direction, at: t)
        hub.set(.leap, leap, at: t)
        let window = strikes.filter { t - $0.t < Self.busyWindow }
        hub.set(.busyness, min(1, Double(window.count) / Self.busyFull), at: t)
        hub.set(.crescendo, Self.crescendo(window), at: t)
        if let lo = held.min(), let hi = held.max() {
            hub.set(.spread, min(1, Double(hi - lo) / 48), at: t)
        } else {
            hub.set(.spread, 0, at: t)
        }
        hub.set(.repetition, repetition, at: t)
        let silence = lastNoteOn.map { min(1, max(0, (t - $0) / Self.silenceFull)) } ?? 1
        hub.set(.silence, silence, at: t)
    }

    // MARK: - Measures

    private var intervals: [Int] {
        zip(melody, melody.dropFirst()).map { Int($1) - Int($0) }
    }

    /// +1 when the top line only rises, -1 when it only falls.
    private var direction: Double {
        let iv = intervals.suffix(6)
        let total = iv.reduce(0) { $0 + abs($1) }
        guard total > 0 else { return 0 }
        return Double(iv.reduce(0, +)) / Double(total)
    }

    private var leap: Double {
        guard let last = intervals.last else { return 0 }
        return min(1, Double(abs(last)) / 12)
    }

    private var repetition: Double {
        guard recent.count >= 4 else { return 0 }
        var best = 0.0
        for k in 2...4 where recent.count > k {
            let positions = recent.count - k
            let matches = (k..<recent.count).filter { recent[$0] == recent[$0 - k] }.count
            best = max(best, Double(matches) / Double(positions))
        }
        return best
    }

    /// Velocity slope; +0.5 per second gives 1.
    private static func crescendo(_ s: [(t: Double, v: Double)]) -> Double {
        guard s.count >= 3 else { return 0 }
        let n = Double(s.count)
        let mt = s.reduce(0) { $0 + $1.t } / n, mv = s.reduce(0) { $0 + $1.v } / n
        let cov = s.reduce(0) { $0 + ($1.t - mt) * ($1.v - mv) }
        let varT = s.reduce(0) { $0 + ($1.t - mt) * ($1.t - mt) }
        guard varT > 0 else { return 0 }
        return max(-1, min(1, (cov / varT) / 0.5))
    }

    static func classify(_ notes: Set<UInt8>) -> ChordQuality {
        let pcs = Set(notes.map { Int($0 % 12) })
        guard pcs.count >= 2 else { return .none }
        for r in pcs {
            if pcs.contains((r + 7) % 12) {
                if pcs.contains((r + 4) % 12) { return .major }
                if pcs.contains((r + 3) % 12) { return .minor }
            }
        }
        for a in pcs { for b in pcs where a != b {
            let d = (b - a + 12) % 12
            if d == 6 || d == 1 { return .tense }
        } }
        for r in pcs where pcs.contains((r + 7) % 12) || pcs.contains((r + 5) % 12) {
            let hasThird = pcs.contains((r + 3) % 12) || pcs.contains((r + 4) % 12)
            if !hasThird { return .open }
        }
        return .none
    }

    private mutating func estimateKey() {
        var best = (score: -Double.infinity, root: 0, minor: false)
        var bestPerRoot = [Double](repeating: -Double.infinity, count: 12)
        for root in 0..<12 {
            for (minor, profile) in [(false, Self.majorProfile), (true, Self.minorProfile)] {
                let rotated = (0..<12).map { profile[($0 - root + 12) % 12] }
                let score = Self.correlation(histogram, rotated)
                if score > best.score { best = (score, root, minor) }
                bestPerRoot[root] = max(bestPerRoot[root], score)
            }
        }
        keyRoot = best.root
        keyIsMinor = best.minor
        let rival = bestPerRoot.indices.filter { $0 != best.root }.map { bestPerRoot[$0] }.max() ?? best.score
        keyConfidence = best.score - rival
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<12 { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
        return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
    }
}
