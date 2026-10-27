/// Turns performance events into key inputs on the hub.
public enum InputRouting {
    public static func route(_ e: PerformanceEvent, into hub: InputHub, at t: Double) {
        switch e {
        case let .noteOn(_, velocity): hub.pulse(.velocity, Double(velocity), at: t)
        case let .pedal(_, amount): hub.set(.pedal, Double(amount), at: t)
        case let .control(controller, value):
            switch controller {
            case 1: hub.set(.modWheel, Double(value), at: t)
            case 11: hub.set(.expression, Double(value), at: t)
            case 66: hub.set(.sostenuto, Double(value), at: t)
            case 67: hub.set(.softPedal, Double(value), at: t)
            default: break
            }
            hub.set(.cc(controller), Double(value), at: t)
        case let .pitchBend(v): hub.set(.pitchBend, Double(v), at: t)
        case let .pressure(v): hub.set(.pressure, Double(v), at: t)
        case let .release(_, speed): hub.pulse(.releaseSpeed, Double(speed), at: t)
        case .allNotesOff: hub.set(.pedal, 0, at: t); hub.set(.pressure, 0, at: t)
        case .noteOff, .chord: break
        }
    }
}
