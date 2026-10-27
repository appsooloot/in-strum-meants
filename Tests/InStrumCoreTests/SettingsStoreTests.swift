import XCTest
@testable import InStrumCore

final class SettingsStoreTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var settingsURL: URL { dir.appendingPathComponent("settings.json") }

    func testRoundTripIncludingPluginState() throws {
        var s = AppSettings.default
        s.instrument = InstrumentChoice(name: "Splice INSTRUMENT", componentType: 0x61756D75,
                                        componentSubType: 0x53706C63, componentManufacturer: 0x53706C63,
                                        stateData: Data([1, 2, 3]))
        s.themeID = "midnight-steinway"; s.masterVolume = 0.5
        let store = SettingsStore(directory: dir)
        try store.save(s)
        XCTAssertEqual(store.load(), s)
    }
    func testMissingFileGivesDefaults() {
        XCTAssertEqual(SettingsStore(directory: dir).load(), .default)
    }
    func testCorruptFileGivesDefaultsAndIsKeptAside() throws {
        try Data("{not json".utf8).write(to: settingsURL)
        XCTAssertEqual(SettingsStore(directory: dir).load(), .default)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.corrupt.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }
    func testUnknownKeysIgnoredAndMissingKeysDefaulted() throws {
        try Data(#"{"themeID":"moonlit-lake","futureThing":42}"#.utf8).write(to: settingsURL)
        let s = SettingsStore(directory: dir).load()
        XCTAssertEqual(s.themeID, "moonlit-lake")
        XCTAssertEqual(s.masterVolume, AppSettings.default.masterVolume)
        XCTAssertNil(s.instrument)
    }
    func testSaveCreatesMissingDirectory() throws {
        let nested = dir.appendingPathComponent("a/b")
        try SettingsStore(directory: nested).save(.default)
        XCTAssertEqual(SettingsStore(directory: nested).load(), .default)
    }
}

final class LaunchGuardTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    func testFirstLaunchIsClean() { XCTAssertFalse(LaunchGuard(directory: dir).beginLaunch()) }
    func testLaunchWithoutMarkStableIsUnclean() {
        _ = LaunchGuard(directory: dir).beginLaunch()
        XCTAssertTrue(LaunchGuard(directory: dir).beginLaunch())
    }
    func testMarkStableMakesNextLaunchClean() {
        let g = LaunchGuard(directory: dir)
        _ = g.beginLaunch(); g.markStable()
        XCTAssertFalse(LaunchGuard(directory: dir).beginLaunch())
    }
}
