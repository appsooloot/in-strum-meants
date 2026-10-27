import CoreMIDI
import Foundation

public enum MIDIInputError: Error { case clientFailed(OSStatus), portFailed(OSStatus) }

/// Listens to every connected MIDI keyboard. Raw MIDI 1.0 bytes are passed on
/// unchanged (parsing happens in InStrumCore) on the CoreMIDI thread.
public final class MIDIInput {
    public private(set) var sourceNames: [String] = []

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: Set<MIDIUniqueID> = []
    private var sawRemoval = false
    private let onSourcesChanged: ([String], Bool) -> Void

    /// - onBytes: raw bytes plus a timestamp in seconds (system uptime), on the CoreMIDI thread.
    /// - onSourcesChanged: current source names, and whether a source was removed.
    public init(onBytes: @escaping ([UInt8], Double) -> Void,
                onSourcesChanged: @escaping (_ names: [String], _ sourceRemoved: Bool) -> Void) throws {
        self.onSourcesChanged = onSourcesChanged
        var status = MIDIClientCreateWithBlock("In Strum Meants" as CFString, &client) { [weak self] note in
            self?.handle(note.pointee)
        }
        guard status == noErr else { throw MIDIInputError.clientFailed(status) }
        status = MIDIInputPortCreateWithProtocol(client, "In Strum Meants In" as CFString, ._1_0, &port) { list, _ in
            let time = ProcessInfo.processInfo.systemUptime
            for bytes in MIDIInput.messages(in: list) where !bytes.isEmpty { onBytes(bytes, time) }
        }
        guard status == noErr else { throw MIDIInputError.portFailed(status) }
        refresh()
    }

    deinit {
        MIDIPortDispose(port)
        MIDIClientDispose(client)
    }

    // MARK: - Sources

    private func handle(_ note: MIDINotification) {
        switch note.messageID {
        case .msgObjectRemoved:
            sawRemoval = true
            refresh()
        case .msgObjectAdded, .msgSetupChanged:
            refresh()
        default:
            break
        }
    }

    private func refresh() {
        var names: [String] = []
        var present: Set<MIDIUniqueID> = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != 0 else { continue }
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(src, kMIDIPropertyUniqueID, &uid)
            present.insert(uid)
            if !connected.contains(uid) { MIDIPortConnectSource(port, src, nil) }
            names.append(Self.name(of: src))
        }
        let removed = sawRemoval || !connected.subtracting(present).isEmpty
        sawRemoval = false
        connected = present
        guard names != sourceNames || removed else { return }
        sourceNames = names
        onSourcesChanged(names, removed)
    }

    private static func name(of endpoint: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cf) == noErr, let s = cf?.takeRetainedValue() {
            return s as String
        }
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &cf) == noErr, let s = cf?.takeRetainedValue() {
            return s as String
        }
        return "MIDI Device"
    }

    // MARK: - Universal MIDI Packet → MIDI 1.0 bytes

    static func messages(in list: UnsafePointer<MIDIEventList>) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var i = 0
                while i < min(count, words.count) {
                    let w = words[i]
                    out.append(bytes(fromUMP: w))
                    i += wordsInMessage(type: UInt8(w >> 28))
                }
            }
        }
        return out
    }

    static func wordsInMessage(type: UInt8) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }

    /// Converts one 32-bit MIDI 1.0 UMP word (types 1 and 2) to raw bytes; other types give [].
    static func bytes(fromUMP w: UInt32) -> [UInt8] {
        let type = w >> 28
        let status = UInt8((w >> 16) & 0xFF)
        let d1 = UInt8((w >> 8) & 0x7F), d2 = UInt8(w & 0x7F)
        switch type {
        case 0x1:
            switch status {
            case 0xF1, 0xF3: return [status, d1]
            case 0xF2: return [status, d1, d2]
            default: return [status]
            }
        case 0x2:
            switch status & 0xF0 {
            case 0xC0, 0xD0: return [status, d1]
            default: return [status, d1, d2]
            }
        default:
            return []
        }
    }
}
