import AVFoundation
import os

/// One of the instrument's own controls (a knob, slider or switch in its window).
public struct DialInfo: Equatable, Hashable {
    public let address: UInt64
    public let name: String
    public init(address: UInt64, name: String) { self.address = address; self.name = name }
}

/// Watches every dial on a loaded instrument so the visuals can follow it.
/// `onChange` may be called on any thread.
public final class DialReader {
    public let dials: [DialInfo]
    public var onChange: ((DialInfo, Double) -> Void)? {
        get { callback.withLock { $0 } }
        set { callback.withLock { $0 = newValue } }
    }

    private let params: [UInt64: AUParameter]
    private let infos: [UInt64: DialInfo]
    private let callback = OSAllocatedUnfairLock<((DialInfo, Double) -> Void)?>(uncheckedState: nil)
    private var token: AUParameterObserverToken?
    private weak var tree: AUParameterTree?

    public init(audioUnit: AUAudioUnit) {
        let all = audioUnit.parameterTree?.allParameters ?? []
        var params: [UInt64: AUParameter] = [:], infos: [UInt64: DialInfo] = [:], list: [DialInfo] = []
        for p in all where params[p.address] == nil {
            let name = p.displayName.isEmpty ? p.identifier : p.displayName
            let info = DialInfo(address: p.address, name: name.isEmpty ? "Dial \(p.address)" : name)
            params[p.address] = p; infos[p.address] = info; list.append(info)
        }
        self.params = params
        self.infos = infos
        self.dials = list
        self.tree = audioUnit.parameterTree
        guard !list.isEmpty, let tree = audioUnit.parameterTree else { return }
        token = tree.token(byAddingParameterObserver: { [weak self] address, value in
            guard let self, let info = self.infos[address], let p = self.params[address] else { return }
            let v = Self.normalise(value, p)
            self.callback.withLock { $0 }?(info, v)
        })
    }

    deinit {
        if let token, let tree { tree.removeParameterObserver(token) }
    }

    /// Every dial's position, 0...1.
    public func currentValues() -> [UInt64: Double] {
        var out: [UInt64: Double] = [:]
        for (a, p) in params { out[a] = Self.normalise(p.value, p) }
        return out
    }

    static func normalise(_ value: AUValue, _ p: AUParameter) -> Double {
        let span = Double(p.maxValue) - Double(p.minValue)
        guard span > 0 else { return 0 }
        return max(0, min(1, (Double(value) - Double(p.minValue)) / span))
    }
}
