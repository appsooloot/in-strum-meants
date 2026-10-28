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
        XCTAssertLessThanOrEqual(gentleBeach.sprayOut, plainBeach.sprayOut * 0.55, "and the spray glints on the foam")
        XCTAssertGreaterThan(plainBeach.sprayOut, 0.5)

        let rd = SceneDirector(themeID: CoastRoadModel.id, state: ThemeState(values: ["lamps": .number(1), "bloom": .number(1)]),
                               reaction: ReactionPresets.expressivePianist)
        rd.sky.reset(settings: MoonlitLakeRendererTests.night)
        rd.handle([60, 64, 67].map { .noteOn(note: $0, velocity: 0.9) }, at: 0)
        var rf: RoadFrame?
        for i in 0..<60 { rf = rd.step(dt: 1.0 / 30, t: Double(i) / 30, quality: .high) as? RoadFrame }
        let roadFrame = try XCTUnwrap(rf)
        XCTAssertGreaterThan(roadFrame.bloom, 0.5)
        let plainRoad = try XCTUnwrap(CoastRoadRenderer(device: device))
        let gentleRoad = try XCTUnwrap(CoastRoadRenderer(device: device))
        for _ in 0..<10 {
            plainRoad.update(roadFrame, params: rd.parameters, quality: .high, gentle: false, dt: 1.0 / 30, size: size)
            gentleRoad.update(roadFrame, params: rd.parameters, quality: .high, gentle: true, dt: 1.0 / 30, size: size)
        }
        XCTAssertGreaterThan(plainRoad.bloomOut, 0.3)
        XCTAssertGreaterThan(plainRoad.lampOut, 0.3)
        XCTAssertLessThanOrEqual(gentleRoad.bloomOut, plainRoad.bloomOut * 0.55, "gentle visuals calm the chord bloom")
        XCTAssertLessThanOrEqual(gentleRoad.lampOut, plainRoad.lampOut * 0.55, "and the lamps")
    }

    func testWarpFieldFollowsQuality() {
        XCTAssertLessThan(WarpLayer.fieldCount(.lite), WarpLayer.fieldCount(.high))
        XCTAssertLessThanOrEqual(WarpLayer.fieldCount(.lite) + GalaxyWarp.cap, 600, "Smooth stays light")
    }
}

/// Luminance helpers for comparing parts of rendered frames (NDC rectangles: x, y in −1…1, y up).
enum FramePatch {
    static func luminance(_ image: CGImage) -> [Double] {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r: Double = Double(px[i * 4]), g: Double = Double(px[i * 4 + 1]), b: Double = Double(px[i * 4 + 2])
            out[i] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        }
        return out
    }

    /// Mean absolute luminance difference between two frames inside an NDC rectangle.
    static func difference(_ a: CGImage, _ b: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>) -> Double {
        let la = luminance(a), lb = luminance(b), w = a.width, h = a.height
        var sum = 0.0, n = 0
        for row in 0..<h {
            let ny = 1 - 2 * (Double(row) + 0.5) / Double(h)
            guard y.contains(ny) else { continue }
            for col in 0..<w {
                let nx = 2 * (Double(col) + 0.5) / Double(w) - 1
                guard x.contains(nx) else { continue }
                sum += abs(la[row * w + col] - lb[row * w + col]); n += 1
            }
        }
        return n > 0 ? sum / Double(n) : 0
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

    /// Steps the beach at 60 fps without notes and captures frames at the given times (seconds, ascending).
    private func beachShots(at times: [Double], state: ThemeState = ThemeState(values: ["keys.show": .bool(false)]))
        throws -> [CGImage] {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(GoldenHourBeachRenderer(device: device))
        let d = SceneDirector(themeID: GoldenHourBeachModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: Self.midday)
        var shots: [CGImage] = []
        var pending = times
        var i = 0
        while let next = pending.first {
            i += 1
            let t = Double(i) / 60
            elapsed = t
            if let f = d.step(dt: 1.0 / 60, t: t, quality: .high) as? BeachFrame {
                r.update(f, params: d.parameters, quality: .high, gentle: false, dt: 1.0 / 60, size: CGSize(width: 640, height: 360))
            }
            if t >= next - 1e-9 { shots.append(try XCTUnwrap(preview.capture(r))); pending.removeFirst() }
        }
        return shots
    }

    func testWavesBreakWithoutAPop() throws {
        // The beach's own swell: find a break a few seconds in.
        var swell = OceanSwell(seed: 0xBEAC4)
        var breakAt = 0.0
        while breakAt < 4 { if let w = swell.step(dt: 1.0 / 60).first { breakAt = w.breakTime } }
        let frame = (breakAt * 60).rounded(.up) / 60
        let shots = try beachShots(at: [frame - 3.0 / 60, frame - 2.0 / 60, frame - 1.0 / 60, frame, frame + 1.0 / 60])
        let sea = (x: -0.5...0.5, y: -0.6...(-0.2))   // keys hidden: the horizon sits at −0.2, the surf below it
        let calm = (1...2).map { FramePatch.difference(shots[$0 - 1], shots[$0], x: sea.x, y: sea.y) }.max() ?? 0
        let across = FramePatch.difference(shots[2], shots[3], x: sea.x, y: sea.y)
        XCTAssertLessThan(across, 2.5 * calm + 0.002, "the break at \(breakAt) s: \(across) vs \(calm) frame to frame")
    }

    func testWashFollowsTheWhiteWater() {
        // The wash slides up the sand when the white water, rolling in from the break line, reaches the waterline.
        let travel = Double((GoldenHourBeachRenderer.breakLine - GoldenHourBeachRenderer.waterline) / GoldenHourBeachRenderer.boreSpeed)
        XCTAssertEqual(travel, OceanSwell.washDelay, accuracy: 0.05)
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

/// Coast Road (Set 4's world) with Coast Lights.
@MainActor
final class CoastRoadRendererTests: XCTestCase {
    func testRoadShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: CoastRoadShaders.source, options: nil)
        for name in ["road_vertex", "road_fragment", "road_lights_vertex", "road_lights_fragment", "road_frame_fragment",
                     "road_keys_vertex", "road_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
    }

    /// Steps the road at 60 fps (notes go down at 0.5 s and stay held) and renders the frame at `seconds`.
    private func renderRoad(notes: [UInt8], at seconds: Double, state: ThemeState, sky: SkySettings? = nil,
                            width: Int = 640, height: Int = 360) throws -> (image: CGImage, renderer: CoastRoadRenderer) {
        let shots = try roadShots(notes: notes, at: [seconds], state: state, sky: sky, width: width, height: height)
        return (shots.images[0], shots.renderer)
    }

    struct RoadShot { var image: CGImage; var frame: RoadFrame; var lampPosts: [SIMD2<Float>] }

    /// Steps the road at 60 fps (notes go down at 0.5 s and stay held) and captures frames at the given times.
    private func roadShots(notes: [UInt8], at times: [Double], state: ThemeState, sky: SkySettings? = nil,
                           width: Int = 640, height: Int = 360) throws -> (images: [CGImage], shots: [RoadShot], renderer: CoastRoadRenderer) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(CoastRoadRenderer(device: device))
        let d = SceneDirector(themeID: CoastRoadModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky ?? GoldenHourBeachRendererTests.midday)
        let size = CGSize(width: width, height: height)
        var shots: [RoadShot] = []
        var pending = times
        var i = 0
        while let next = pending.first {
            i += 1
            let t = Double(i) / 60
            elapsed = t
            if i == 30 { d.handle(notes.map { .noteOn(note: $0, velocity: 1) }, at: t) }
            guard let f = d.step(dt: 1.0 / 60, t: t, quality: .high) as? RoadFrame else { continue }
            r.update(f, params: d.parameters, quality: .high, gentle: false, dt: 1.0 / 60, size: size)
            if t >= next - 1e-9 {
                shots.append(RoadShot(image: try XCTUnwrap(preview.capture(r)), frame: f, lampPosts: r.lampPosts))
                pending.removeFirst()
            }
        }
        return (shots.map(\.image), shots, r)
    }

    func testNoRainInsideTheCar() throws {
        var rain = GoldenHourBeachRendererTests.midday; rain.weather = .rain
        let shots = try roadShots(notes: [], at: [3, 3.5], state: ThemeState(values: ["keys.show": .bool(false)]), sky: rain)
        let a = shots.images[0], b = shots.images[1]
        // The headliner above the glass and the door trim below it don't change from moment to moment.
        XCTAssertLessThan(FramePatch.difference(a, b, x: -0.99...(-0.6), y: 0.93...0.99), 0.002, "headliner")
        XCTAssertLessThan(FramePatch.difference(a, b, x: -0.9...0.9, y: -0.99...(-0.92)), 0.002, "door trim")
        XCTAssertGreaterThan(FramePatch.difference(a, b, x: -0.6...0.6, y: -0.3...0.6), 0.002, "while the view outside moves")
    }

    func testHighNotesLightLampsThatPassWithTheRoad() throws {
        let state = ThemeState(values: ["keys.show": .bool(false)])
        let run = try roadShots(notes: [84, 96], at: [1.0, 1.5], state: state)
        for shot in run.shots {
            let lamps = shot.frame.lights.filter { $0.lane == .lamp }
            XCTAssertEqual(lamps.count, 2)
            XCTAssertEqual(shot.lampPosts.count, lamps.count, "every lamp light stands on a post")
        }
        // They pass at the lamps' own pace: each moves left by the distance travelled × the lamp layer's rate.
        let moved = zip(run.shots[0].lampPosts, run.shots[1].lampPosts).map { $0.x - $1.x }
        let travelled = Float(run.shots[1].frame.distance - run.shots[0].frame.distance)
        for m in moved { XCTAssertEqual(m, travelled * CoastRoadRenderer.lampLayerRate, accuracy: 0.002) }
        XCTAssertEqual(Double(CoastRoadRenderer.lampLayerRate), 3.3 / CoastRoadRenderer.lampSpacing, accuracy: 1e-6)
    }

    func testFarSeaDoesNotFizz() throws {
        let state = ThemeState(values: ["keys.show": .bool(false), "sway": .number(0)])
        let shots = try roadShots(notes: [], at: [3, 3 + 1.0 / 60], state: state).images
        // Keys hidden: the window runs from −0.9 to 0.9 and the horizon sits 62% of the way up it.
        let horizon = -0.9 + 1.8 * 0.62
        let far = FramePatch.difference(shots[0], shots[1], x: -0.8...0.8, y: (horizon - 0.12)...(horizon - 0.02))
        let near = FramePatch.difference(shots[0], shots[1], x: -0.8...0.8, y: -0.45...(-0.3))
        XCTAssertLessThanOrEqual(far, near + 0.002, "far \(far), near \(near)")
    }

    func testRoadPreviewIsStructured() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        for q in [QualityLevel.lite, .high] {
            let image = try XCTUnwrap(preview.render(themeID: CoastRoadModel.id, at: [5], quality: q,
                                                     sky: GoldenHourBeachRendererTests.midday).first)
            let s = PreviewRenderer.stats(image)
            XCTAssertGreaterThan(s.meanLuminance, 0.03, "\(q)")
            XCTAssertGreaterThan(s.variance, 0.001, "\(q)")
        }
    }

    func testLampsLightAtBlueHour() throws {
        // No notes, keys hidden: the lamps are the only change.
        func patch(lamps: Double) throws -> Double {
            let shot = try renderRoad(notes: [], at: 3, state: ThemeState(values: ["lamps": .number(lamps), "keys.show": .bool(false)]))
            return PreviewRenderer.brightestPatch(shot.image, radius: 4)
        }
        let lit = try patch(lamps: 1), dark = try patch(lamps: 0)
        XCTAssertGreaterThan(lit, 1.3 * dark, "lamps light up at blue hour")
    }

    func testCoastLightsShowWhilePlaying() throws {
        let state = ThemeState(values: ["keys.show": .bool(false), "bloom": .number(0)])
        let played = try renderRoad(notes: [36, 43, 52, 60, 64, 67, 76, 84, 91], at: 1.2, state: state)
        let quiet = try renderRoad(notes: [], at: 1.2, state: state)
        XCTAssertGreaterThan(played.renderer.lightCount, 4)
        XCTAssertEqual(quiet.renderer.lightCount, 0)
        XCTAssertGreaterThan(PreviewRenderer.difference(played.image, quiet.image), 0.002)
    }

    func testRoadFramesAnyAspect() throws {
        for (w, h) in [(864, 360), (360, 360)] {
            let shot = try renderRoad(notes: [60, 64, 67], at: 2, state: ThemeState(), width: w, height: h)
            let s = PreviewRenderer.stats(shot.image)
            XCTAssertGreaterThan(s.meanLuminance, 0.03, "\(w)×\(h)")
            XCTAssertGreaterThan(s.variance, 0.001, "\(w)×\(h)")
            XCTAssertEqual(shot.renderer.keyRects.count, 88)
            for k in shot.renderer.keyRects {
                XCTAssertGreaterThanOrEqual(k.x, -1); XCTAssertLessThanOrEqual(k.z, 1)
                XCTAssertGreaterThanOrEqual(k.y, -1); XCTAssertLessThanOrEqual(k.w, 1)
            }
        }
    }

    func testShadersSquareWithoutPow() throws {
        // pow() of a negative base is undefined under fast math (NaN on some GPUs): squares are written x * x.
        let pattern = try NSRegularExpression(pattern: #"pow\([^;]*?,\s*2\.0\)"#)
        let shared = SkyShaders.common.count + OceanShaders.common.count
        for (name, full) in [("road", CoastRoadShaders.source), ("beach", GoldenHourBeachShaders.source), ("ocean", OceanShaders.common)] {
            let source = name == "ocean" ? full : String(full.dropFirst(shared))
            let hits = pattern.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
            XCTAssertEqual(hits, 0, name)
        }
    }

    func testLightBudgetFollowsQuality() {
        XCTAssertEqual(CoastRoadRenderer.lightBudget(.lite), 64)
        XCTAssertEqual(CoastRoadRenderer.lightBudget(.high), CoastLights.cap)
    }

    func testWeatherLayerReusesItsBuffers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 160, height: 90))
        let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 13; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .rain
        let rain = LivingSky(settings: s, homeZone: TimeZone(identifier: "Australia/Melbourne")!)
            .step(now: Date(timeIntervalSince1970: 1_793_000_000), dt: 0)
        for i in 0..<120 {
            r.update(rain, quality: .high, size: CGSize(width: 160, height: 90), dt: 1.0 / 60, time: Float(i) / 60, surface: .water(horizonY: -0.3))
            _ = preview.capture(r)
        }
        XCTAssertGreaterThan(r.weather.particleCount, 300, "heavy enough to need a buffer")
        XCTAssertLessThanOrEqual(r.weather.bufferAllocations, 4, "instance buffers are kept and grown, not made every frame")
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

    func testWriteRoadPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let held = ThemeState()
        let golden = ThemeState(values: ["light.hold": .choice(SkyHold.goldenHour.rawValue)])
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        let warp = ThemeState(values: ["visual": .choice("Galaxy Warp")])
        let cases: [(String, SkySettings, ThemeState, QualityLevel, Double)] = [
            ("road-blue", sky(hour: 13, phase: 0.5), held, .high, 5),
            ("road-golden", sky(hour: 13, phase: 0.5), golden, .high, 5),
            ("road-night", sky(hour: 1, phase: 0.5), follow, .high, 5),
            ("road-rain", sky(hour: 13, phase: 0.5, weather: .rain), held, .high, 5),
            ("road-fog", sky(hour: 13, phase: 0.5, weather: .mist), held, .high, 5),
            ("road-smooth", sky(hour: 13, phase: 0.5), held, .lite, 5),
            ("road-lights-t6", sky(hour: 13, phase: 0.5), held, .high, 6),
            ("road-warp-t7", sky(hour: 13, phase: 0.5), warp, .high, 7),
        ]
        for (name, s, state, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: CoastRoadModel.id, at: [t], state: state, quality: q, sky: s).first)
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
