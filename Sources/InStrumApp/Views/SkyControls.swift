import SwiftUI
import InStrumCore

/// ✦ Visuals → World: the Living Sky's time, place and weather, and the world's ambience.
struct SkyControls: View {
    @ObservedObject var model: AppModel
    @State private var citySearch = ""

    private var sky: SkySettings { model.skySettings }
    private var ambience: AmbienceSettings { model.ambienceSettings }
    /// The lounge is in space: no weather to choose.
    private var hasWeather: Bool { model.themeID != SpaceshipLoungeModel.id }

    private func update(_ change: (inout SkySettings) -> Void) {
        var s = sky
        change(&s)
        model.setSky(s)
    }

    private var cities: [City] { Self.filtered(Cities.all, query: citySearch, keeping: sky.cityID) }

    /// The picker's cities for a search, by name; the selected city always stays in the list so the picker
    /// never loses its selection while you type.
    static func filtered(_ all: [City], query: String, keeping selected: String?) -> [City] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = all.sorted { $0.name < $1.name }
        guard !q.isEmpty else { return sorted }
        return sorted.filter { $0.id == selected || $0.name.lowercased().contains(q) || $0.country.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Time", selection: Binding(get: { sky.timeMode }, set: { m in update { $0.timeMode = m } })) {
                Text("Quick day").tag(TimeMode.quick)
                Text("Real time").tag(TimeMode.realTime)
                Text("Frozen").tag(TimeMode.frozen)
            }
            .pickerStyle(.segmented)

            switch sky.timeMode {
            case .quick:
                labelled("A day lasts \(Int(sky.dayMinutes.rounded())) min") {
                    Slider(value: Binding(get: { sky.dayMinutes }, set: { v in update { $0.dayMinutes = v } }), in: 2...60, step: 1)
                }
            case .frozen:
                labelled("Time \(Self.clock(sky.frozenHour))") {
                    Slider(value: Binding(get: { sky.frozenHour }, set: { v in update { $0.frozenHour = v } }), in: 0...23.99)
                }
                labelled("Moon: \(Self.phaseName(sky.frozenPhase))") {
                    Slider(value: Binding(get: { sky.frozenPhase }, set: { v in update { $0.frozenPhase = v } }), in: 0...1)
                }
            case .realTime:
                Text("The sun, moon and stars as they are right now over your city.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            labelled("City") {
                TextField("Search cities", text: $citySearch).textFieldStyle(.roundedBorder)
                Picker("", selection: Binding(get: { sky.cityID ?? "" }, set: { id in update { $0.cityID = id.isEmpty ? nil : id } })) {
                    Text("Follow my Mac's time zone").tag("")
                    ForEach(cities) { c in Text("\(c.name), \(c.country)").tag(c.id) }
                }
                .labelsHidden()
            }

            if hasWeather {
                Picker("Weather", selection: Binding(get: { sky.weatherMode }, set: { m in update { $0.weatherMode = m } })) {
                    Text("Random, beautiful").tag(WeatherMode.randomBeautiful)
                    Text("Pick").tag(WeatherMode.pick)
                }
                .pickerStyle(.segmented)
                if sky.weatherMode == .pick {
                    Picker("", selection: Binding(get: { sky.weather }, set: { w in update { $0.weather = w } })) {
                        ForEach(WeatherKind.allCases, id: \.self) { Text(Self.weatherName($0)).tag($0) }
                    }
                    .labelsHidden()
                }
            }

            Divider()
            Toggle("Ambience", isOn: Binding(get: { ambience.enabled }, set: { model.setAmbienceEnabled($0) }))
            if ambience.enabled {
                labelled("Volume \(Int((ambience.volume * 100).rounded()))%") {
                    Slider(value: Binding(get: { ambience.volume }, set: { model.setAmbienceVolume($0) }), in: 0...1)
                }
                labelled(ambience.closeness < 0.35 ? "Distant" : (ambience.closeness > 0.65 ? "All around you" : "Closeness")) {
                    Slider(value: Binding(get: { ambience.closeness }, set: { model.setAmbienceCloseness($0) }), in: 0...1)
                }
            }
        }
    }

    @ViewBuilder
    private func labelled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout)
            content()
        }
    }

    static func clock(_ hour: Double) -> String {
        let minutes = Int((hour * 60).rounded()) % (24 * 60)
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    static func phaseName(_ p: Double) -> String {
        switch p {
        case ..<0.03, 0.97...: return "new"
        case ..<0.22: return "waxing crescent"
        case ..<0.28: return "first quarter"
        case ..<0.47: return "waxing gibbous"
        case ..<0.53: return "full"
        case ..<0.72: return "waning gibbous"
        case ..<0.78: return "last quarter"
        default: return "waning crescent"
        }
    }

    static func weatherName(_ w: WeatherKind) -> String {
        switch w {
        case .clear: return "Clear"
        case .lightCloud: return "Light cloud"
        case .overcast: return "Overcast"
        case .mist: return "Mist"
        case .drizzle: return "Drizzle"
        case .rain: return "Rain"
        case .storm: return "Storm"
        case .snow: return "Snow"
        case .blizzard: return "Blizzard"
        case .afterRain: return "After the rain"
        case .sunShower: return "Sun-shower"
        }
    }
}
