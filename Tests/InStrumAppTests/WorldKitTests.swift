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

    func testWorldsHonourGentleVisuals() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        func lakeFrame() -> (LakeFrame, ParameterSet) {
            let d = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
            d.sky.reset(settings: MoonlitLakeRendererTests.night)
            d.handle([60, 64, 67, 72].map { .noteOn(note: $0, velocity: 0.9) }, at: 0)
            var f: LakeFrame?
            for i in 0..<90 { f = d.step(dt: 1.0 / 30, t: Double(i) / 30, quality: .high) as? LakeFrame }   // glitter settles toward 1
            return (f!, d.parameters)
        }
        let (frame, params) = lakeFrame()
        XCTAssertGreaterThan(frame.glitter, 0.9)
        let size = CGSize(width: 640, height: 360)
        let plain = try XCTUnwrap(MoonlitLakeRenderer(device: device))
        let gentle = try XCTUnwrap(MoonlitLakeRenderer(device: device))
        for _ in 0..<10 {
            plain.update(frame, params: params, quality: .high, gentle: false, dt: 1.0 / 30, size: size)
            gentle.update(frame, params: params, quality: .high, gentle: true, dt: 1.0 / 30, size: size)
        }
        XCTAssertGreaterThan(plain.glitterOut, 0.5)
        XCTAssertEqual(gentle.glitterOut, plain.glitterOut * 0.5, accuracy: 1e-4, "gentle visuals halve the glints")
        XCTAssertEqual(gentle.fireflyScale, 0.5, accuracy: 1e-4)
        XCTAssertEqual(plain.fireflyScale, 1, accuracy: 1e-4)

        let ld = SceneDirector(themeID: SpaceshipLoungeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        ld.sky.reset(settings: MoonlitLakeRendererTests.night)
        ld.handle([.noteOn(note: 60, velocity: 1)], at: 0)
        let lf = try XCTUnwrap(ld.step(dt: 1.0 / 30, t: 0, quality: .high) as? LoungeFrame)
        let lounge = try XCTUnwrap(SpaceshipLoungeRenderer(device: device))
        lounge.update(lf, params: ld.parameters, quality: .high, gentle: true, dt: 1.0 / 30, size: size)
        XCTAssertEqual(lounge.streakScale, 0.5, accuracy: 1e-4, "gentle visuals halve the streaks")
        lounge.update(lf, params: ld.parameters, quality: .high, gentle: false, dt: 1.0 / 30, size: size)
        XCTAssertEqual(lounge.streakScale, 1, accuracy: 1e-4)

        let bd = SceneDirector(themeID: GoldenHourBeachModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        bd.sky.reset(settings: MoonlitLakeRendererTests.night)
        bd.handle([60, 64, 67, 72].map { .noteOn(note: $0, velocity: 0.9) }, at: 0)
        var bf: BeachFrame?
        for i in 0..<90 { bf = bd.step(dt: 1.0 / 30, t: Double(i) / 30, quality: .high) as? BeachFrame }
        let beachFrame = try XCTUnwrap(bf)
        let plainBeach = try XCTUnwrap(GoldenHourBeachRenderer(device: device))
        let gentleBeach = try XCTUnwrap(GoldenHourBeachRenderer(device: device))
        for _ in 0..<10 {
            plainBeach.update(beachFrame, params: bd.parameters, quality: .high, gentle: false, dt: 1.0 / 30, size: size)
            gentleBeach.update(beachFrame, params: bd.parameters, quality: .high, gentle: true, dt: 1.0 / 30, size: size)
        }
        XCTAssertGreaterThan(plainBeach.glitterOut, 0.3)
        XCTAssertLessThanOrEqual(gentleBeach.glitterOut, plainBeach.glitterOut * 0.55, "gentle visuals calm the sun's path")
    }

    func testWarpFieldFollowsQuality() {
        XCTAssertLessThan(WarpLayer.fieldCount(.lite), WarpLayer.fieldCount(.high))
        XCTAssertLessThanOrEqual(WarpLayer.fieldCount(.lite) + GalaxyWarp.cap, 600, "Smooth stays light")
    }
}

/// Golden Hour Beach (Set 3's world) with Tide Lines and the shared Ocean layer.
@MainActor
final class GoldenHourBeachRendererTests: XCTestCase {
    func testBeachShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: GoldenHourBeachShaders.source, options: nil)
        for name in ["beach_vertex", "beach_fragment", "beach_keys_vertex", "beach_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
    }

    static var midday: SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 13; s.frozenPhase = 0.5; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = .clear
        return s
    }

    /// Steps the beach at 60 fps (notes go down at 0.5 s and stay held) and renders the frame at `seconds`.
    private func renderBeach(notes: [UInt8], at seconds: Double, state: ThemeState, width: Int = 640, height: Int = 360)
        throws -> (image: CGImage, renderer: GoldenHourBeachRenderer, frame: BeachFrame) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(GoldenHourBeachRenderer(device: device))
        let d = SceneDirector(themeID: GoldenHourBeachModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: Self.midday)
        var frame: BeachFrame?
        let size = CGSize(width: width, height: height)
        for i in 1...Int(seconds * 60) {
            let t = Double(i) / 60
            elapsed = t
            if i == 30 { d.handle(notes.map { .noteOn(note: $0, velocity: 1) }, at: t) }
            frame = d.step(dt: 1.0 / 60, t: t, quality: .high) as? BeachFrame
            if let frame { r.update(frame, params: d.parameters, quality: .high, gentle: false, dt: 1.0 / 60, size: size) }
        }
        let f = try XCTUnwrap(frame)
        return (try XCTUnwrap(preview.capture(r)), r, f)
    }

    func testBeachPreviewIsStructured() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        for q in [QualityLevel.lite, .high] {
            let image = try XCTUnwrap(preview.render(themeID: GoldenHourBeachModel.id, at: [5], quality: q, sky: Self.midday).first)
            let s = PreviewRenderer.stats(image)
            XCTAssertGreaterThan(s.meanLuminance, 0.08, "\(q)")
            XCTAssertGreaterThan(s.variance, 0.002, "\(q)")
        }
    }

    func testLinesShowOnTheSand() throws {
        // Keys hidden, glitter and foam off: the lines are the only thing the notes change.
        let state = ThemeState(values: ["keys.show": .bool(false), "glitter": .number(0), "foam": .number(0)])
        let notes: [UInt8] = [36, 48, 55, 60, 64, 67, 72, 76, 84, 96]
        let played = try renderBeach(notes: notes, at: 1.5, state: state)
        let quiet = try renderBeach(notes: [], at: 1.5, state: state)
        XCTAssertGreaterThan(played.renderer.lineCount, 4)
        XCTAssertEqual(quiet.renderer.lineCount, 0)
        XCTAssertGreaterThan(PreviewRenderer.difference(played.image, quiet.image), 0.003)
    }

    func testSunAndMoonLightBlend() {
        var s = SkyState()
        s.moon = SkyDirection(azimuth: 20, altitude: 30); s.moonLit = 1
        var last: (sun: Float, moon: Float)?
        var alt = -10.0
        while alt <= 6 + 1e-9 {
            s.sun = SkyDirection(azimuth: 300, altitude: alt)
            let l = OceanLight.lights(s)
            if let last {
                XCTAssertLessThan(abs(l.sun.w - last.sun), 0.05, "sun at \(alt)°")
                XCTAssertLessThan(abs(l.moon.w - last.moon), 0.05, "moon at \(alt)°")
            }
            last = (l.sun.w, l.moon.w)
            alt += 0.1
        }
        s.sun = SkyDirection(azimuth: 300, altitude: -10)
        XCTAssertGreaterThan(OceanLight.lights(s).moon.w, 0.9, "the moon lights the sea at night")
        s.sun = SkyDirection(azimuth: 300, altitude: 6)
        XCTAssertGreaterThan(OceanLight.lights(s).sun.w, 0.9, "the sun lights it by day")
        XCTAssertLessThan(OceanLight.lights(s).moon.w, 0.01)
    }

    func testOceanStaysSmoothAfterHours() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let state = ThemeState(values: ["keys.show": .bool(false)])
        let base = try renderBeach(notes: [], at: 2, state: state).frame
        let swell = OceanSwell(seed: 0xBEAC4)
        func at(_ t: Double) -> BeachFrame {
            var f = base
            let shift = t - base.swellTime
            f.time = t; f.swellTime = t
            f.swellPhases = swell.phases(at: t)
            f.upcoming = base.upcoming.map { var w = $0; w.breakTime += shift; return w }
            f.recent = base.recent.map { var w = $0; w.breakTime += shift; return w }
            return f
        }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let size = CGSize(width: 640, height: 360)
        func image(_ frames: [BeachFrame]) throws -> CGImage {
            let r = try XCTUnwrap(GoldenHourBeachRenderer(device: device))
            for f in frames { r.update(f, params: ThemeRegistry.parameterSet(for: GoldenHourBeachModel.id, state: state),
                                       quality: .high, gentle: false, dt: 1.0 / 60, size: size) }
            return try XCTUnwrap(preview.capture(r))
        }
        let late = 36_000.0
        let a = try image((0..<30).map { at(late - Double(30 - $0) / 60) })
        let b = try image((0..<31).map { at(late - Double(30 - $0) / 60) })
        XCTAssertLessThan(PreviewRenderer.difference(a, b), 0.01, "one frame apart, ten hours in")
        let early = try image((0..<30).map { at(60 - Double(30 - $0) / 60) })
        let ratio = PreviewRenderer.stats(a).variance / max(PreviewRenderer.stats(early).variance, 1e-9)
        XCTAssertGreaterThan(ratio, 0.5); XCTAssertLessThan(ratio, 2, "the sea keeps its detail after hours")
    }

    func testBeachFramesAnyAspect() throws {
        for (w, h) in [(864, 360), (360, 360)] {
            let shot = try renderBeach(notes: [60, 64, 67], at: 2, state: ThemeState(), width: w, height: h)
            let s = PreviewRenderer.stats(shot.image)
            XCTAssertGreaterThan(s.meanLuminance, 0.05, "\(w)×\(h)")
            XCTAssertGreaterThan(s.variance, 0.001, "\(w)×\(h)")
            XCTAssertEqual(shot.renderer.keyRects.count, 88)
            for k in shot.renderer.keyRects {
                XCTAssertGreaterThanOrEqual(k.x, -1); XCTAssertLessThanOrEqual(k.z, 1)
                XCTAssertGreaterThanOrEqual(k.y, -1); XCTAssertLessThanOrEqual(k.w, 1)
            }
        }
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

    func testWriteBeachPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let held = ThemeState()
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        let warp = ThemeState(values: ["visual": .choice("Galaxy Warp")])
        let cases: [(String, SkySettings, ThemeState, QualityLevel, Double)] = [
            ("beach-golden", sky(hour: 13, phase: 0.5), held, .high, 5),
            ("beach-blue", sky(hour: 20.5, phase: 0.5), follow, .high, 5),
            ("beach-night", sky(hour: 1, phase: 0.5), follow, .high, 5),
            ("beach-rain", sky(hour: 13, phase: 0.5, weather: .rain), held, .high, 5),
            ("beach-storm", sky(hour: 13, phase: 0.5, weather: .storm), held, .high, 5),
            ("beach-fog", sky(hour: 13, phase: 0.5, weather: .mist), held, .high, 5),
            ("beach-smooth", sky(hour: 13, phase: 0.5), held, .lite, 5),
            ("beach-lines-t6", sky(hour: 13, phase: 0.5), held, .high, 6),
            ("beach-warp-t7", sky(hour: 13, phase: 0.5), warp, .high, 7),
        ]
        for (name, s, state, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: GoldenHourBeachModel.id, at: [t], state: state, quality: q, sky: s).first)
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
