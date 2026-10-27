import SwiftUI
import InStrumCore

struct SettingsPopover: View {
    @ObservedObject var model: AppModel
    @State private var buffer: UInt32 = 256

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Touch").font(.headline)
                Picker("Touch", selection: Binding(get: { model.touchCurve }, set: { model.setTouchCurve($0) })) {
                    ForEach(TouchCurve.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text("Heavy keeps soft playing soft. Light makes loud notes easier.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Audio buffer").font(.headline)
                Picker("Audio buffer", selection: Binding(get: { buffer }, set: { buffer = $0; model.setBufferFrames($0) })) {
                    Text("128 · fastest").tag(UInt32(128))
                    Text("256 · balanced").tag(UInt32(256))
                    Text("512 · safest").tag(UInt32(512))
                }
                .pickerStyle(.segmented).labelsHidden()
                Text("If you hear crackles or glitches, choose a larger buffer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { buffer = model.bufferFrames }
    }
}
