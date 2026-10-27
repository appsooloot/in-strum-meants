import SwiftUI
import InStrumAudio

struct InstrumentPicker: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var search = ""
    @State private var plugins: [PluginInfo] = []
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
            Text("After choosing, press Open Plugin Window to pick a sound, such as Intimate Grand Piano.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Search instruments", text: $search).textFieldStyle(.roundedBorder)
            List(filtered) { plugin in
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
                    .disabled(loading != nil)
                }
                .padding(.vertical, 2)
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
        .onAppear { plugins = PluginCatalog.instruments() }
    }
}
