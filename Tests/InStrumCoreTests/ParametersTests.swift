import XCTest
@testable import InStrumCore

final class ParametersTests: XCTestCase {
    let specs: [ParamSpec] = [
        ParamSpec(id: "s", name: "S", group: "A", help: "", kind: .slider(0...1), defaultValue: .number(0.5), hero: true, surprise: 0.2...0.8),
        ParamSpec(id: "w", name: "W", group: "A", help: "", kind: .slider(0...10), defaultValue: .number(2), hero: false, surprise: nil),
        ParamSpec(id: "n", name: "N", group: "B", help: "", kind: .integer(20...1200), defaultValue: .number(300), hero: false, surprise: nil),
        ParamSpec(id: "c", name: "C", group: "B", help: "", kind: .choice(["One", "Two"]), defaultValue: .choice("One"), hero: false, surprise: nil),
        ParamSpec(id: "t", name: "T", group: "B", help: "", kind: .toggle, defaultValue: .bool(true), hero: false, surprise: nil),
        ParamSpec(id: "g", name: "G", group: "C", help: "", kind: .gradient,
                  defaultValue: .gradient([GradientStop(position: 0, color: RGBA(0, 0, 0)), GradientStop(position: 1, color: RGBA(1, 1, 1))]),
                  hero: false, surprise: nil),
    ]

    func testSliderClampsToRange() {
        var p = ParameterSet(specs: specs)
        p.set("s", .number(5))
        XCTAssertEqual(p.number("s"), 1.0)
    }
    func testIntegerRoundsAndClamps() {
        var p = ParameterSet(specs: specs)
        p.set("n", .number(5000.4))
        XCTAssertEqual(p.number("n"), 1200)
        p.set("n", .number(99.6))
        XCTAssertEqual(p.number("n"), 100)
    }
    func testChoiceMustBeAnOption() {
        var p = ParameterSet(specs: specs)
        p.set("c", .choice("Two")); p.set("c", .choice("Nope"))
        XCTAssertEqual(p.choice("c"), "Two")
    }
    func testWrongKindValueFallsBackToDefault() {
        let p = ParameterSet(specs: specs, saved: ["s": .choice("x"), "w": .number(4)])
        XCTAssertEqual(p.number("s"), 0.5)
        XCTAssertEqual(p.number("w"), 4)
    }
    func testToggleReadsAsNumber() {
        XCTAssertEqual(ParameterSet(specs: specs).number("t"), 1)
    }
    func testResetSingleGroupAll() {
        var p = ParameterSet(specs: specs)
        p.set("s", .number(0.9)); p.set("w", .number(9)); p.set("c", .choice("Two"))
        p.reset("s"); XCTAssertEqual(p.number("s"), 0.5); XCTAssertEqual(p.number("w"), 9)
        p.resetGroup("A"); XCTAssertEqual(p.number("w"), 2); XCTAssertEqual(p.choice("c"), "Two")
        p.resetAll(); XCTAssertEqual(p.choice("c"), "One")
    }
    func testSavedContainsOnlyNonDefaults() {
        var p = ParameterSet(specs: specs)
        p.set("s", .number(0.5)); p.set("w", .number(3))
        XCTAssertEqual(p.saved, ["w": .number(3)])
    }
    func testMacroScalesAroundBase() {
        var p = ParameterSet(specs: specs, macroTargets: [.intensity: [("s", 1)]])
        p.macros[.intensity] = 1
        XCTAssertEqual(p.number("s"), 1.0, accuracy: 1e-9)
        p.macros[.intensity] = -0.5
        XCTAssertEqual(p.number("s"), 0.25, accuracy: 1e-9)
        XCTAssertEqual(p.baseNumber("s"), 0.5)
    }
    func testOffsetsAddFractionOfRange() {
        let p = ParameterSet(specs: specs).withOffsets(["w": 0.5])
        XCTAssertEqual(p.number("w"), 7, accuracy: 1e-9)
    }
    func testGradientNeedsTwoToSixStops() {
        var p = ParameterSet(specs: specs)
        let one = [GradientStop(position: 0, color: RGBA(1, 0, 0))]
        p.set("g", .gradient(one))
        guard case let .gradient(stops) = p.value("g") else { return XCTFail() }
        XCTAssertEqual(stops.count, 2)
    }
    func testUnknownIdReadsZero() {
        XCTAssertEqual(ParameterSet(specs: specs).number("missing"), 0)
    }
}

final class ThemeStateSettingsTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    func testBuild2SettingsStillLoad() throws {
        let json = #"{"bufferFrames":512,"instrument":{"componentManufacturer":1,"componentSubType":2,"componentType":3,"name":"Splice INSTRUMENT"},"masterVolume":0.7,"themeID":"midnight-steinway","touchCurve":"heavy"}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let s = SettingsStore(directory: dir).load()
        XCTAssertEqual(s.instrument?.name, "Splice INSTRUMENT")
        XCTAssertEqual(s.touchCurve, .heavy); XCTAssertEqual(s.bufferFrames, 512)
        XCTAssertTrue(s.themeStates.isEmpty)
        XCTAssertEqual(s.quality, .auto); XCTAssertFalse(s.gentleVisuals)
    }
    func testThemeStateRoundTrips() throws {
        var s = AppSettings.default
        s.themeStates["butterfly-garden"] = ThemeState(values: ["wings.style": .choice("Monarch"), "rays": .number(0.7)],
                                                      macros: [.speed: 0.3], lookPresetName: "Monarch Morning")
        s.quality = .lite; s.gentleVisuals = true
        let store = SettingsStore(directory: dir)
        try store.save(s)
        XCTAssertEqual(store.load(), s)
    }
}
