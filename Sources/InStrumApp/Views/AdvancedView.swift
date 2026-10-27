import SwiftUI
import InStrumCore

/// Advanced: every setting, the mapping editor, and (later) controls.
struct AdvancedView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text("All settings").tag(0)
                    Text("Mapping").tag(1)
                    Text("Controls").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)
                Spacer()
                Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            switch tab {
            case 0: AllSettingsView(model: model)
            case 1: MappingEditorView(model: model)
            default: ControlsView(model: model)
            }
        }
        .frame(width: 720, height: 620)
    }
}

struct AllSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""

    private var state: ThemeState { model.themeState(for: model.themeID) }
    private var params: ParameterSet { ThemeRegistry.parameterSet(for: model.themeID, state: state) }
    private var specs: [ParamSpec] {
        let all = ThemeRegistry.parameters(for: model.themeID)
        guard !search.isEmpty else { return all }
        return all.filter { "\($0.name) \($0.group) \($0.help)".localizedCaseInsensitiveContains(search) }
    }
    private var groups: [String] {
        var seen: [String] = []
        for s in specs where !seen.contains(s.group) { seen.append(s.group) }
        return seen
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search settings", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 14).padding(.top, 10)
            List {
                ForEach(groups, id: \.self) { group in
                    Section {
                        ForEach(specs.filter { $0.group == group }) { spec in
                            HStack(alignment: .top) {
                                ParamControl(spec: spec, value: params.baseValue(spec.id) ?? spec.defaultValue) { v in
                                    model.saveThemeState(VisualSettings.updated(state, themeID: model.themeID, id: spec.id, to: v), for: model.themeID)
                                }
                                Button { reset(spec.id) } label: { Image(systemName: "arrow.counterclockwise") }
                                    .buttonStyle(.borderless).help("Reset to default")
                            }
                        }
                    } header: {
                        HStack {
                            Text(group)
                            Spacer()
                            Button("Reset group") { resetGroup(group) }.buttonStyle(.borderless).font(.caption)
                        }
                    }
                }
            }
        }
    }

    private func reset(_ id: String) {
        var set = params; set.reset(id)
        var s = state; s.values = set.saved; s.lookPresetName = nil
        model.saveThemeState(s, for: model.themeID)
    }
    private func resetGroup(_ group: String) {
        var set = params; set.resetGroup(group)
        var s = state; s.values = set.saved; s.lookPresetName = nil
        model.saveThemeState(s, for: model.themeID)
    }
}

struct MappingEditorView: View {
    @ObservedObject var model: AppModel
    @State private var naming = false
    @State private var newName = ""

    private var map: ReactionMap { model.reaction }
    private func update(_ m: ReactionMap) { model.setReactionMap(m) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Reacts like: \(model.reactionName)").font(.headline)
                Spacer()
                Button { update(MappingEdits.addLink(map)) } label: { Label("Add link", systemImage: "plus") }
                Button("Save as Reaction preset…") { newName = ""; naming = true }
            }
            .padding(.horizontal, 14).padding(.top, 10)
            HStack(spacing: 14) {
                ForEach(InputFamily.allCases, id: \.self) { f in strengthSlider(f) }
            }
            .padding(.horizontal, 14)
            List {
                ForEach(MappingEdits.groups(map), id: \.family) { group in
                    Section(group.family.displayName) {
                        ForEach(group.links) { link in row(link) }
                    }
                }
            }
        }
        .alert("Name these reactions", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { model.saveReaction(named: n) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func strengthBinding(_ f: InputFamily) -> Binding<Double> {
        Binding(get: { map.groupStrength[f] ?? 1 }, set: { v in
            var m = map
            m.groupStrength[f] = v
            update(m)
        })
    }

    private func strengthSlider(_ f: InputFamily) -> some View {
        VStack(spacing: 2) {
            Text(f.displayName).font(.caption2).foregroundStyle(.secondary)
            Slider(value: strengthBinding(f), in: 0...2).frame(width: 110)
        }
    }

    private func row(_ link: InStrumCore.Link) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { link.enabled }, set: { on in update(MappingEdits.edit(map, link: link.id) { $0.enabled = on }) }))
                .labelsHidden()
            Picker("", selection: Binding(get: { link.input }, set: { i in update(MappingEdits.edit(map, link: link.id) { $0.input = i }) })) {
                ForEach(MappingEdits.inputs(seen: [link.input]), id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden().frame(width: 180)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { link.target }, set: { t in update(MappingEdits.retarget(map, link: link.id, to: t)) })) {
                ForEach(MappingEdits.targets(for: model.themeID), id: \.self) { Text(MappingEdits.targetName($0, themeID: model.themeID)).tag($0) }
            }
            .labelsHidden().frame(width: 150)
            Slider(value: Binding(get: { link.amount }, set: { a in update(MappingEdits.edit(map, link: link.id) { $0.amount = a }) }), in: -1...1)
                .frame(width: 110)
            Picker("", selection: Binding(get: { link.curve }, set: { c in update(MappingEdits.edit(map, link: link.id) { $0.curve = c }) })) {
                Text("Gentle").tag(Curve.gentle); Text("Linear").tag(Curve.linear); Text("Snappy").tag(Curve.snappy)
            }
            .labelsHidden().frame(width: 80)
            Button { update(MappingEdits.remove(map, link: link.id)) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
        }
    }
}

/// Filled in by the hands-free controls task.
struct ControlsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Text("Keyboard shortcuts and MIDI-learn are coming in the next build.")
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
