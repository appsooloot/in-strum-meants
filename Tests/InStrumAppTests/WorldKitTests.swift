import XCTest
import Metal
@testable import InStrumApp
@testable import InStrumCore

@MainActor
final class WorldKitTests: XCTestCase {
    func testSkyShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: SkyShaders.source, options: nil)
        for name in ["sky_dome_vertex", "sky_dome_fragment", "weather_vertex", "weather_fragment", "ring_vertex", "ring_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
    }

    private func render(_ state: SkyState, quality: QualityLevel = .high, weather: WeatherSurface = .none, frames: Int = 1) throws -> CGImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
        for i in 0..<frames { r.update(state, quality: quality, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, time: Float(i) / 30, surface: weather) }
        return try XCTUnwrap(preview.capture(r))
    }

    private func frozen(_ hour: Double, weather: WeatherKind = .clear) -> SkyState {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = weather
        return LivingSky(settings: s, homeZone: TimeZone(identifier: "Australia/Melbourne")!).step(now: Date(timeIntervalSince1970: 1_793_000_000), dt: 0)
    }

    func testSkyRendersNightAndDay() throws {
        let night = PreviewRenderer.stats(try render(frozen(2))).meanLuminance
        let day = PreviewRenderer.stats(try render(frozen(13))).meanLuminance
        XCTAssertLessThan(night, 0.08)
        XCTAssertGreaterThan(day, 0.35)
        XCTAssertGreaterThan(PreviewRenderer.stats(try render(frozen(2))).variance, 0, "stars")
    }

    /// Night, clear, moon 30° up straight ahead: a full moon lights a bigger, brighter patch than a crescent.
    func testFullMoonBrighterThanCrescent() throws {
        func moonState(_ phase: Double) -> SkyState {
            var s = frozen(2)
            s.sun = SkyDirection(azimuth: 180, altitude: -40)
            s.moon = SkyDirection(azimuth: SkyLayer.defaultViewAzimuth(latitude: s.latitude), altitude: 30)
            s.moonPhase = phase
            s.moonLit = (1 - cos(2 * .pi * phase)) / 2
            return s
        }
        let full = PreviewRenderer.brightestPatch(try render(moonState(0.5)), radius: 12)
        let crescent = PreviewRenderer.brightestPatch(try render(moonState(0.1)), radius: 12)
        XCTAssertGreaterThan(full, crescent * 1.5, "full \(full) crescent \(crescent)")
    }

    func testWeatherLayerScalesWithQualityAndAmount() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let w = try XCTUnwrap(WeatherLayer(device: device))
        var s = frozen(13, weather: .rain)
        s.rain = 1
        w.update(s, quality: .lite, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, surface: .water(horizonY: -0.2))
        XCTAssertEqual(w.particleCount, 400)
        w.update(s, quality: .ultra, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, surface: .water(horizonY: -0.2))
        XCTAssertEqual(w.particleCount, 2500)
        s.rain = 0.5
        w.update(s, quality: .high, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, surface: .glass)
        XCTAssertEqual(w.particleCount, 600)
        s.rain = 0; s.snow = 0
        w.update(s, quality: .high, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, surface: .none)
        XCTAssertEqual(w.particleCount, 0)
    }

    func testRainyNightRendersAndLightningIsLimited() throws {
        var s = frozen(2, weather: .storm)
        s.rain = 1; s.cloudCover = 1; s.lightning = 1
        let image = try render(s, weather: .water(horizonY: -0.2), frames: 20)
        XCTAssertGreaterThan(PreviewRenderer.stats(image).variance, 0)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let w = try XCTUnwrap(WeatherLayer(device: device))
        var boosts: [Float] = []
        for i in 0..<60 {   // a flash request every frame for 2 s: the limiter allows at most 3 big jumps a second
            s.lightning = i % 2 == 0 ? 1 : 0
            w.update(s, quality: .lite, size: CGSize(width: 320, height: 180), dt: 1.0 / 30, surface: .none)
            boosts.append(w.exposureBoost)
        }
        var jumps = 0
        for i in 3..<boosts.count where boosts[i] - boosts[i - 3] > FlashLimiter.flashRise { jumps += 1 }
        XCTAssertLessThanOrEqual(jumps, 2 * 3 * 3, "limited")
        XCTAssertGreaterThan(boosts.max() ?? 1, 1, "lightning does brighten the scene")
    }
}

/// Moonlit Lake (Set 1's world) with Lake Ripples.
@MainActor
final class MoonlitLakeRendererTests: XCTestCase {
    func testLakeShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: MoonlitLakeShaders.source, options: nil)
        for name in ["lake_vertex", "lake_fragment", "firefly_vertex", "firefly_fragment", "lake_keys_vertex", "lake_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
    }

    static var night: SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 22; s.frozenPhase = 0.55; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = .clear
        return s
    }

    func testLakePreviewIsStructured() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        for q in [QualityLevel.lite, .high] {
            let image = try XCTUnwrap(preview.render(themeID: MoonlitLakeModel.id, at: [5], quality: q, sky: Self.night, mood: .serene).first)
            let s = PreviewRenderer.stats(image)
            XCTAssertGreaterThan(s.meanLuminance, 0.03, "\(q)")
            XCTAssertGreaterThan(s.variance, 0.001, "\(q)")
        }
        // The demo's hard low note lands at 2.0 s: the lake answers it.
        let frames = preview.render(themeID: MoonlitLakeModel.id, at: [1.95, 2.35], quality: .high, sky: Self.night, mood: .serene)
        XCTAssertEqual(frames.count, 2)
        XCTAssertGreaterThan(PreviewRenderer.difference(frames[0], frames[1]), 0.005)
    }
}

/// Spaceship Lounge (Set 2's world) with Galaxy Warp.
@MainActor
final class SpaceshipLoungeRendererTests: XCTestCase {
    func testLoungeShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: SpaceshipLoungeShaders.source, options: nil)
        for name in ["lounge_vertex", "lounge_space_fragment", "lounge_frame_fragment", "lounge_keys_vertex", "lounge_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
        let warp = try device.makeLibrary(source: WarpShaders.source, options: nil)
        for name in ["warp_streak_vertex", "warp_streak_fragment", "warp_nebula_vertex", "warp_nebula_fragment"] {
            XCTAssertNotNil(warp.makeFunction(name: name), name)
        }
    }

    func testLoungeHasNoWeatherSurface() {
        if case .none = SpaceshipLoungeRenderer.weatherSurface {} else { XCTFail("the lounge is in space: no weather") }
    }

    func testLoungePreviewIsStructured() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        for q in [QualityLevel.lite, .high] {
            let image = try XCTUnwrap(preview.render(themeID: SpaceshipLoungeModel.id, at: [5], quality: q,
                                                     sky: MoonlitLakeRendererTests.night, mood: .dreamy).first)
            let s = PreviewRenderer.stats(image)
            XCTAssertGreaterThan(s.meanLuminance, 0.03, "\(q)")
            XCTAssertGreaterThan(s.variance, 0.001, "\(q)")
        }
        // The demo's hard low note lands at 2.0 s: stars streak past the window.
        let frames = preview.render(themeID: SpaceshipLoungeModel.id, at: [1.95, 2.35], quality: .high,
                                    sky: MoonlitLakeRendererTests.night, mood: .dreamy)
        XCTAssertEqual(frames.count, 2)
        XCTAssertGreaterThan(PreviewRenderer.difference(frames[0], frames[1]), 0.005)
    }

    func testWarpFieldFollowsQuality() {
        XCTAssertLessThan(WarpLayer.fieldCount(.lite), WarpLayer.fieldCount(.high))
        XCTAssertLessThanOrEqual(WarpLayer.fieldCount(.lite) + GalaxyWarp.cap, 600, "Smooth stays light")
    }
}

/// World preview frames for the CI previews branch (PREVIEW_DIR).
@MainActor
final class WorldPreviewTests: XCTestCase {
    private func sky(hour: Double, phase: Double, weather: WeatherKind = .clear) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = weather
        return s
    }

    func testWriteLakePreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let cases: [(String, SkySettings, QualityLevel, Double)] = [
            ("lake-night-t5", sky(hour: 22, phase: 0.55), .high, 5),
            ("lake-dusk-t5", sky(hour: 19.9, phase: 0.3), .high, 5),
            ("lake-moonrise-t5", sky(hour: 20.1, phase: 0.5), .high, 5),
            ("lake-rain-t5", sky(hour: 22, phase: 0.55, weather: .rain), .high, 5),
            ("lake-smooth-t5", sky(hour: 22, phase: 0.55), .lite, 5),
            ("lake-ripples-t2.5", sky(hour: 22, phase: 0.55), .high, 2.5),
        ]
        for (name, s, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: MoonlitLakeModel.id, at: [t], quality: q, sky: s, mood: .serene).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
    }

    func testWriteLoungePreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let cases: [(String, SkySettings, QualityLevel, Double)] = [
            ("lounge-t5", sky(hour: 22, phase: 0.55), .high, 5),
            ("lounge-warp-t7", sky(hour: 22, phase: 0.55), .high, 7),
            ("lounge-smooth-t5", sky(hour: 22, phase: 0.55), .lite, 5),
            ("lounge-sunrise-t5", sky(hour: 5.9, phase: 0.3), .high, 5),
            ("lounge-day-t5", sky(hour: 13, phase: 0.7), .high, 5),
        ]
        for (name, s, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: SpaceshipLoungeModel.id, at: [t], quality: q, sky: s, mood: .dreamy).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
        let warpLake = ThemeState(values: ["visual": .choice("Galaxy Warp")])
        let image = try XCTUnwrap(preview.render(themeID: MoonlitLakeModel.id, at: [7], state: warpLake, quality: .high,
                                                 sky: sky(hour: 22, phase: 0.55), mood: .serene).first)
        try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("lake-warp-t7.png"))
    }
}

/// Living Sky preview frames for the CI previews branch (PREVIEW_DIR).
@MainActor
final class SkyPreviewTests: XCTestCase {
    func testWriteSkyPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let cases: [(String, Double, Double, WeatherKind, WeatherSurface)] = [
            ("sky-night-full-moon", 23.5, 0.5, .clear, .none),
            ("sky-night-crescent-milky-way", 3.0, 0.15, .clear, .none),
            ("sky-dawn", 6.6, 0.3, .lightCloud, .none),
            ("sky-golden-hour", 18.9, 0.6, .lightCloud, .none),
            ("sky-day-clouds", 12.5, 0.6, .lightCloud, .none),
            ("sky-rain-night-water", 22.0, 0.5, .rain, .water(horizonY: -0.33)),
            ("sky-snow-dusk", 19.6, 0.4, .snow, .ground(horizonY: -0.33)),
            ("sky-storm-glass", 15.0, 0.5, .storm, .glass),
        ]
        for (name, hour, phase, weather, surface) in cases {
            var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
            s.weatherMode = .pick; s.weather = weather
            let sky = LivingSky(settings: s, homeZone: TimeZone(identifier: "Australia/Melbourne")!)
            let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
            var state = sky.step(now: Date(timeIntervalSince1970: 1_793_000_000), dt: 0)
            for i in 0..<45 {
                state = sky.step(now: Date(timeIntervalSince1970: 1_793_000_000 + Double(i) / 30), dt: 1.0 / 30)
                r.update(state, quality: .high, size: CGSize(width: 1280, height: 720), dt: 1.0 / 30, time: Float(i) / 30, surface: surface)
            }
            let image = try XCTUnwrap(preview.capture(r))
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
    }
}
