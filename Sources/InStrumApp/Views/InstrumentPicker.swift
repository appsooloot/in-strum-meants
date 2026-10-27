import SwiftUI
import InStrumAudio

struct InstrumentPicker: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var search = ""
    @State private var plugins: [PluginInfo] = []
    @State private var builtIns: [PluginInfo] = []
    @State private var loading: String?

    private var filtered: [PluginInfo] {
        guard !search.isEmpty else { return plugins }
        return plugins.filter { "\($0.manufacturer) \($0.name)".localizedCaseInsensitiveContains(search) }
    }

    private var message: String? {
        if case let .needsInstrument(m) = model.status { return m }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose an instrument").font(.title2.bold())
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("After choosing, press Open Instrument (or Open Plugin Window) to pick a sound, such as Intimate Grand Piano.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Search instruments", text: $search).textFieldStyle(.roundedBorder)
            List {
                Section("In Strum Meants: made in the app, yours forever") {
                    if builtIns.isEmpty {
                        Text("Built-in instruments couldn't start. Your plugins still work.").foregroundStyle(.secondary)
                    }
                    ForEach(builtIns) { row($0) }
                }
                Section("Installed instruments") {
                    ForEach(filtered) { row($0) }
                }
            }
            .frame(minHeight: 280)
            HStack {
                Text("\(plugins.count) instruments installed").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { isPresented = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
        .onAppear {
            plugins = PluginCatalog.instruments()
            builtIns = BuiltInCatalog.instruments
        }
    }

    private func row(_ plugin: PluginInfo) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(plugin.name).font(.body.weight(.medium))
                Text(plugin.manufacturer).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if loading == plugin.id { ProgressView().controlSize(.small) }
            Button("Choose") {
                loading = plugin.id
                Task {
                    await model.choose(plugin)
                    loading = nil
                    if case .playing = model.status { isPresented = false }
                }
            }
            .disabled(loading != nil || model.isLoading)
        }
        .padding(.vertical, 2)
    }
}
