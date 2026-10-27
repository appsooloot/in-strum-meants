import SwiftUI
import AppKit
import InStrumCore

/// One setting, drawn from its declaration.
struct ParamControl: View {
    let spec: ParamSpec
    let value: ParamValue
    let onChange: (ParamValue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(spec.name).font(.callout)
                Spacer()
                if case let .number(x) = value, spec.range != nil {
                    Text(label(x)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            control
            if !spec.help.isEmpty { Text(spec.help).font(.caption2).foregroundStyle(.tertiary) }
        }
        .help(spec.help)
    }

    private func label(_ x: Double) -> String {
        if case .integer = spec.kind { return String(Int(x)) }
        return String(format: "%.2f", x)
    }

    @ViewBuilder private var control: some View {
        switch spec.kind {
        case let .slider(range):
            Slider(value: Binding(get: { number }, set: { onChange(.number($0)) }), in: range)
        case let .integer(range):
            Slider(value: Binding(get: { number }, set: { onChange(.number($0.rounded())) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
        case .toggle:
            Toggle("", isOn: Binding(get: { number > 0.5 }, set: { onChange(.bool($0)) })).labelsHidden()
        case let .choice(options):
            Picker("", selection: Binding(get: { choice }, set: { onChange(.choice($0)) })) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        case .color:
            ColorPicker("", selection: Binding(get: { Self.color(rgba) }, set: { onChange(.color(Self.rgba($0))) }))
                .labelsHidden()
        case .gradient:
            HStack {
                ForEach(Array(stops.enumerated()), id: \.offset) { i, stop in
                    ColorPicker("", selection: Binding(get: { Self.color(stop.color) }, set: { c in
                        var s = stops; s[i].color = Self.rgba(c); onChange(.gradient(s))
                    })).labelsHidden()
                }
            }
        }
    }

    private var number: Double {
        switch value { case let .number(x): return x; case let .bool(b): return b ? 1 : 0; default: return 0 }
    }
    private var choice: String { if case let .choice(c) = value { return c }; return "" }
    private var rgba: RGBA { if case let .color(c) = value { return c }; return RGBA(1, 1, 1) }
    private var stops: [GradientStop] { if case let .gradient(g) = value { return g }; return [] }

    static func color(_ c: RGBA) -> Color { Color(red: c.r, green: c.g, blue: c.b, opacity: c.a) }
    static func rgba(_ c: Color) -> RGBA {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
        return RGBA(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}
