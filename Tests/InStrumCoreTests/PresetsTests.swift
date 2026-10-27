import XCTest
@testable import InStrumCore

final class PresetsTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let specs = ButterflyGardenModel.parameters

    func testLookRoundTrip() throws {
        let store = PresetStore(directory: dir)
        let p = LookPreset(name: "My Dawn", themeID: ButterflyGardenModel.id,
                           state: ThemeState(values: ["time": .choice("Dawn")], macros: [.glow: 0.3]), favourite: true)
        try store.save(p)
        XCTAssertEqual(store.looks(for: ButterflyGardenModel.id).first { $0.name == "My Dawn" }, p)
        XCTAssertTrue(store.looks(for: MidnightSteinwayModel.id).allSatisfy { $0.name != "My Dawn" })
    }
    func testReactionRoundTripAndDelete() throws {
        let store = PresetStore(directory: dir)
        let p = ReactionPreset(name: "Mine", map: ReactionPresets.wild, favourite: false)
        try store.save(p)
        XCTAssertEqual(store.reactions().first { $0.name == "Mine" }, p)
        try store.delete(reaction: "Mine")
        XCTAssertNil(store.reactions().first { $0.name == "Mine" })
    }
    func testNamesWithSlashesAreSafe() throws {
        let store = PresetStore(directory: dir)
        try store.save(ReactionPreset(name: "a/b: c", map: ReactionPresets.minimal, favourite: false))
        XCTAssertNotNil(store.reactions().first { $0.name == "a/b: c" })
    }
    func testDamagedFileListedAndOthersLoad() throws {
        let store = PresetStore(directory: dir)
        try store.save(ReactionPreset(name: "Good", map: ReactionPresets.minimal, favourite: false))
        try Data("{broken".utf8).write(to: dir.appendingPathComponent("reaction/bad.json"))
        let all = store.reactions()
        XCTAssertNotNil(all.first { $0.name == "Good" })
        XCTAssertTrue(store.unreadable.contains("bad.json"))
    }
    func testSurpriseStaysInTastefulRanges() {
        for seed in 0..<100 {
            let state = Surprise.look(specs: specs, seed: UInt64(seed))
            for s in specs {
                guard let v = state.values[s.id] else { continue }
                XCTAssertNotNil(s.surprise, "\(s.id) changed but is not surprisable")
                if case let .number(x) = v, let r = s.surprise, s.range != nil {
                    XCTAssertTrue(r.contains(x) || abs(x - r.upperBound) < 1, "\(s.id)=\(x)")
                }
                XCTAssertEqual(s.validated(v), v, "\(s.id) invalid")
            }
        }
    }
    func testSurpriseVariesWithSeed() {
        XCTAssertNotEqual(Surprise.look(specs: specs, seed: 1), Surprise.look(specs: specs, seed: 2))
    }
    func testMorphEndsMidpointAndChoices() {
        let a = ThemeState(values: ["rays": .number(0.2), "time": .choice("Dawn")])
        let b = ThemeState(values: ["rays": .number(0.8), "time": .choice("Moonlight")])
        XCTAssertEqual(morph(a, b, specs: specs, t: 0).values["rays"], .number(0.2))
        XCTAssertEqual(morph(a, b, specs: specs, t: 1).values["rays"], .number(0.8))
        guard case let .number(mid)? = morph(a, b, specs: specs, t: 0.5).values["rays"] else { return XCTFail() }
        XCTAssertEqual(mid, 0.5, accuracy: 1e-9)
        XCTAssertEqual(morph(a, b, specs: specs, t: 0.49).values["time"], .choice("Dawn"))
        XCTAssertEqual(morph(a, b, specs: specs, t: 0.5).values["time"], .choice("Moonlight"))
    }
    func testMorphUsesDefaultsForMissingValues() {
        let a = ThemeState(), b = ThemeState(values: ["rays": .number(0.95)])
        guard case let .number(mid)? = morph(a, b, specs: specs, t: 0.5).values["rays"] else { return XCTFail() }
        XCTAssertEqual(mid, (0.55 + 0.95) / 2, accuracy: 1e-9)
    }
    func testBuiltInReactionsAreSixAndStayInRange() {
        let all = ReactionPresets.all
        XCTAssertEqual(all.map(\.name), ["Expressive Pianist", "Calm Ambient", "Synth Explorer", "Music Party", "Minimal", "Wild"])
        var full = InputFrame()
        for l in all.flatMap(\.map.links) { full.values[l.input] = 1 }
        for p in all {
            let roles = p.map.evaluate(full).roles
            for r in Role.allCases {
                XCTAssertTrue((r.isSigned ? -1.0...1.0 : 0.0...1.0).contains(roles[r]), "\(p.name) \(r)")
            }
        }
    }
    func testBuiltInLooksAreValid() {
        XCTAssertEqual(ButterflyGardenModel.builtInLooks.map(\.name),
                       ["Monarch Morning", "Morpho Dream", "Golden Hour Meadow", "Moonlit Moths", "Crystal Garden", "Neon Night"])
        for look in ButterflyGardenModel.builtInLooks {
            let set = ParameterSet(specs: specs, saved: look.state.values)
            XCTAssertEqual(set.saved.count, look.state.values.filter { specs.first(where: { s in s.id == $0.key })?.defaultValue != $0.value }.count, look.name)
            XCTAssertEqual(look.themeID, ButterflyGardenModel.id)
        }
    }
}
