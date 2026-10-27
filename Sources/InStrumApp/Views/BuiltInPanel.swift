import AppKit
import AVFoundation
import SwiftUI
import InStrumAudio
import InStrumCore

/// The window for the app's own instruments: presets, dials, tuning and the song that inspired it.
struct BuiltInPanel: View {
    @ObservedObject var model: AppModel
    let unit: BuiltInInstrumentAU
    @State private var refresh = 0

    private var dials: [AUParameter] {
        (unit.parameterTree?.allParameters ?? []).filter {
            !Mood.parameterIdentifiers.contains($0.identifier) && $0.identifier != "fineTune" && $0.identifier != "transpose"
        }
    }

    private func parameter(_ identifier: String) -> AUParameter? {
        unit.parameterTree?.allParameters.first { $0.identifier == identifier }
    }

    private func binding(_ p: AUParameter) -> Binding<Double> {
        Binding(get: { _ = refresh; return Double(p.value) },
                set: { p.value = AUValue($0); refresh += 1 })
    }

    private func stepper(_ identifier: String) -> Binding<Double> {
        Binding(get: { _ = refresh; return Double(parameter(identifier)?.value ?? 0) },
                set: { parameter(identifier)?.value = AUValue($0.rounded()); refresh += 1 })
    }

    private var currentPatch: Patch? { model.builtInPatch }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(unit.engine.displayName).font(.title2.weight(.semibold))
                Spacer()
                Menu(currentPatch?.name ?? "Presets") {
                    ForEach(PatchLibrary.patches(for: unit.engine)) { patch in
                        Button(patch.displayName) { model.applyPatch(patch); refresh += 1 }
                    }
                }
                .frame(width: 200)
            }
            VStack(spacing: 10) {
                ForEach(dials, id: \.address) { p in
                    HStack {
                        Text(p.displayName).frame(width: 90, alignment: .leading)
                        Slider(value: binding(p), in: Double(p.minValue)...Double(p.maxValue))
                    }
                }
            }
            Divider()
            HStack(spacing: 24) {
                Stepper(value: stepper("fineTune"), in: -50...50, step: 1) {
                    Text("Fine tune \(Int(stepper("fineTune").wrappedValue)) cents").monospacedDigit()
                }
                Stepper(value: stepper("transpose"), in: -12...12, step: 1) {
                    Text("Transpose \(Int(stepper("transpose").wrappedValue))").monospacedDigit()
                }
            }
            .help("Fine tune locks onto a recording that sits slightly off standard pitch.")
            if let credit = currentPatch?.credit ?? PatchLibrary.defaultPatch(for: unit.engine).credit {
                InspiredByText(credit: credit)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// Text version of the "Inspired by" card (the living artwork arrives with the Sets gallery).
struct InspiredByText: View {
    let credit: Credit
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("INSPIRED BY").font(.caption2.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
            Text("“\(credit.song)”").font(.headline)
            Text("\(credit.artist) · \(credit.album) (\(String(credit.year)))").font(.subheadline).foregroundStyle(.secondary)
            Text(credit.line).font(.callout).italic().padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }
}

/// Shows the built-in instrument panel in its own window.
@MainActor
final class BuiltInPanelController: NSObject, NSWindowDelegate {
    static let shared = BuiltInPanelController()
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    func show(model: AppModel, unit: BuiltInInstrumentAU) {
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        onClose = { model.autosave() }
        let host = NSHostingController(rootView: BuiltInPanel(model: model, unit: unit))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.title = unit.engine.displayName
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    func owns(_ window: NSWindow?) -> Bool { window != nil && window === self.window }

    func close() {
        guard let w = window else { return }
        w.delegate = nil
        onClose?()
        w.close()
        w.contentViewController = nil
        window = nil
        onClose = nil
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        window?.contentViewController = nil
        window = nil
        onClose = nil
    }
}
