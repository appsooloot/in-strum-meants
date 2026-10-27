import SwiftUI
import InStrumCore

/// Look presets, Save, Surprise me, Morph A↔B and the reaction style.
struct PresetBar: View {
    @ObservedObject var model: AppModel
    @State private var naming: NamingTarget?
    @State private var newName = ""
    @State private var morphA: String = ""
    @State private var morphB: String = ""
    @State private var morphT: Double = 0

    enum NamingTarget: Identifiable { case look, reaction; var id: Int { self == .look ? 0 : 1 } }

    private var looks: [LookPreset] { model.lookPresets() }
    private var current: String? { model.themeState(for: model.themeID).lookPresetName }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu(current ?? "Look presets") {
                    ForEach(looks) { look in
                        Button(look.name) { model.applyLook(look) }
                    }
                    Divider()
                    Button("Save current look…") { newName = ""; naming = .look }
                }
                Button { model.surprise() } label: { Label("Surprise me", systemImage: "dice") }
            }
            if looks.count >= 2 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Morph between two looks").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        picker($morphA)
                        Slider(value: $morphT, in: 0...1) { _ in } onEditingChanged: { _ in }
                            .onChange(of: morphT) { _ in applyMorph() }
                        picker($morphB)
                    }
                }
            }
            HStack {
                Text("Reacts like").font(.callout)
                Menu(model.reactionName) {
                    ForEach(model.allReactions()) { r in
                        Button(r.name) { model.setReaction(r) }
                    }
                    Divider()
                    Button("Save current reactions…") { newName = ""; naming = .reaction }
                }
            }
        }
        .onAppear {
            if morphA.isEmpty { morphA = looks.first?.name ?? "" }
            if morphB.isEmpty { morphB = looks.dropFirst().first?.name ?? "" }
        }
        .alert(naming == .reaction ? "Name these reactions" : "Name this look",
               isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                if naming == .reaction { model.saveReaction(named: name) } else { model.saveLook(named: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func picker(_ selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            ForEach(looks) { Text($0.name).tag($0.name) }
        }
        .labelsHidden()
        .frame(width: 90)
    }

    private func applyMorph() {
        guard let a = looks.first(where: { $0.name == morphA }), let b = looks.first(where: { $0.name == morphB }) else { return }
        var state = morph(a.state, b.state, specs: ThemeRegistry.parameters(for: model.themeID), t: morphT)
        state.lookPresetName = nil
        model.saveThemeState(state, for: model.themeID)
    }
}
