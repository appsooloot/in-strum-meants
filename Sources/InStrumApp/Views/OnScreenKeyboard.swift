import SwiftUI
import AppKit
import InStrumCore

/// Shown when no MIDI keyboard is connected. Play with the mouse,
/// or the Mac keyboard (A W S E D F T G Y H U J K; Z / X change octave).
struct OnScreenKeyboard: View {
    @ObservedObject var model: AppModel
    static let low: UInt8 = 48, high: UInt8 = 84
    @State private var keyMap = ComputerKeyMap()
    @State private var held: Set<UInt8> = []
    @State private var heldByKey: [UInt16: UInt8] = [:]
    @State private var monitor: Any?

    var body: some View {
        GeometryReader { geo in
            let keys = KeyboardLayout.keys(from: Self.low, to: Self.high)
            ZStack(alignment: .topLeading) {
                ForEach(keys, id: \.note) { key in
                    let w = CGFloat(key.width) * geo.size.width
                    let h = key.isBlack ? geo.size.height * 0.62 : geo.size.height
                    RoundedRectangle(cornerRadius: 3)
                        .fill(fill(key))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.5), lineWidth: 0.5))
                        .frame(width: w - 1, height: h)
                        .offset(x: CGFloat(key.x) * geo.size.width)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { _ in press(key.note) }
                            .onEnded { _ in release(key.note) })
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .topTrailing) {
            Text("No keyboard connected · play with mouse or A–K · Z/X octave (\(keyMap.octaveShift >= 0 ? "+" : "")\(keyMap.octaveShift))")
                .font(.caption2).foregroundStyle(.secondary).padding(4)
        }
        .onAppear(perform: installMonitor)
        .onDisappear(perform: removeMonitor)
    }

    private func fill(_ key: KeyRect) -> Color {
        let down = held.contains(key.note)
        if key.isBlack { return down ? Color(red: 0.55, green: 0.38, blue: 0.2) : Color(red: 0.08, green: 0.07, blue: 0.06) }
        return down ? Color(red: 1, green: 0.8, blue: 0.55) : Color(red: 0.95, green: 0.92, blue: 0.87)
    }

    private func press(_ note: UInt8) {
        guard !held.contains(note) else { return }
        held.insert(note)
        model.playFromScreen(note: note, down: true)
    }

    private func release(_ note: UInt8) {
        guard held.remove(note) != nil else { return }
        model.playFromScreen(note: note, down: false)
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            if NSApp.keyWindow?.firstResponder is NSText { return event }   // typing in a text field
            guard let ch = event.charactersIgnoringModifiers?.first else { return event }
            if event.type == .keyDown {
                if event.isARepeat { return nil }
                if keyMap.handleOctaveKey(ch) { return nil }
                guard let note = keyMap.note(for: ch) else { return event }
                heldByKey[event.keyCode] = note
                press(note)
            } else {
                guard let note = heldByKey.removeValue(forKey: event.keyCode) else { return event }
                release(note)
            }
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for note in held { model.playFromScreen(note: note, down: false) }
        held.removeAll()
        heldByKey.removeAll()
    }
}
