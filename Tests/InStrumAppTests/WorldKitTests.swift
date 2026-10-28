import XCTest
import Metal
import simd
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

    // MARK: - Halos, the Belt of Venus, pastel dawns, blizzards

    /// The NDC point where an east-north-up direction lands on a 640×360 sky frame.
    private func screenPoint(_ dir: SkyDirection, sky: SkyLayer, latitude: Double) -> (x: Double, y: Double) {
        let cam = sky.camera(latitude: latitude, aspect: 640.0 / 360)
        let d = SkyLayer.enu(dir)
        let f = simd_dot(d, cam.forward)
        return (Double(simd_dot(d, cam.right) / f / cam.tanH), Double(simd_dot(d, cam.up) / f / cam.tanV))
    }

    /// Mean RGB (0…1) of a small square around an NDC point.
    private func rgb(_ image: CGImage, at p: (x: Double, y: Double), radius: Int = 3) -> SIMD3<Double> {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let cx = Int((p.x + 1) / 2 * Double(w)), cy = Int((1 - p.y) / 2 * Double(h))
        var sum = SIMD3<Double>(repeating: 0), n = 0.0
        for row in max(0, cy - radius)...min(h - 1, cy + radius) {
            for col in max(0, cx - radius)...min(w - 1, cx + radius) {
                let i = (row * w + col) * 4
                sum += SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2])) / 255; n += 1
            }
        }
        return sum / max(1, n)
    }

    private func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    private func renderSky(_ state: SkyState, viewAzimuth: Double?) throws -> (image: CGImage, sky: SkyLayer) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
        r.sky.viewAzimuth = viewAzimuth
        r.update(state, quality: .high, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, time: 0, surface: .none)
        return (try XCTUnwrap(preview.capture(r)), r.sky)
    }

    /// A clear morning with the sun 10° up straight ahead: halos forced on brighten the sundog's spot (22°/cos 10° to
    /// the right) well above a point 15° from the sun; with halo 0 the two match.
    func testHalosAppearAroundTheSun() throws {
        var s = frozen(13)
        let view = SkyLayer.defaultViewAzimuth(latitude: s.latitude)
        s.sun = SkyDirection(azimuth: view, altitude: 10)
        func ratio(halo: Float) throws -> Double {
            var st = s; st.halo = halo
            let (image, sky) = try renderSky(st, viewAzimuth: view)
            let dog = screenPoint(SkyDirection(azimuth: view + HaloOptics.sundogOffset(sunAltitude: 10), altitude: 10), sky: sky, latitude: s.latitude)
            let near = screenPoint(SkyDirection(azimuth: view + 15, altitude: 10), sky: sky, latitude: s.latitude)
            return luma(rgb(image, at: dog)) / max(1e-6, luma(rgb(image, at: near)))
        }
        let on = try ratio(halo: 1), off = try ratio(halo: 0)
        XCTAssertGreaterThanOrEqual(on, 1.15, "sundog against 15°: \(on)")
        XCTAssertEqual(off, 1, accuracy: 0.05, "without halos: \(off)")
    }

    /// Dusk, the sun 3° down: looking away from it, a pink band sits about 10° up; looking 90° from the sun it doesn't.
    func testBeltOfVenusIsPink() throws {
        var s = frozen(13)
        s.sun = SkyDirection(azimuth: 90, altitude: -3)
        let c = SkyPalette.colours(sunAltitude: -3, cloud: 0, mist: s.mist, moonlight: 0)
        s.zenith = c.zenith; s.horizon = c.horizon; s.starVisibility = 0
        // Red over green (a difference: ratios flatten under the tone curve).
        func pinkness(view: Double) throws -> Double {
            let (image, sky) = try renderSky(s, viewAzimuth: view)
            let p = rgb(image, at: screenPoint(SkyDirection(azimuth: view, altitude: 10), sky: sky, latitude: s.latitude))
            return p.x - p.y
        }
        let away = try pinkness(view: 270), side = try pinkness(view: 0)
        XCTAssertGreaterThan(away, 1.1 * side, "away \(away) side \(side)")
    }

    /// The same dawn frame, pastel against plain: a pinker, less orange horizon and a lavender zenith.
    func testPastelDawnTintsTheSky() throws {
        var s = frozen(13)
        s.sun = SkyDirection(azimuth: 90, altitude: -2)
        s.cloudCover = 0; s.starVisibility = 0
        func frame(pastel: Float) throws -> (horizon: SIMD3<Double>, zenith: SIMD3<Double>) {
            var st = s
            let c = SkyPalette.colours(sunAltitude: -2, cloud: 0, mist: s.mist, moonlight: 0, pastel: pastel)
            st.zenith = c.zenith; st.horizon = c.horizon; st.dawnPastel = pastel
            let (image, sky) = try renderSky(st, viewAzimuth: 0)
            return (rgb(image, at: screenPoint(SkyDirection(azimuth: 0, altitude: 2), sky: sky, latitude: s.latitude), radius: 5),
                    rgb(image, at: (0, 0.9), radius: 5))
        }
        let plain = try frame(pastel: 0), pastel = try frame(pastel: 1)
        let hPlain = plain.horizon.z / plain.horizon.x, hPastel = pastel.horizon.z / pastel.horizon.x
        XCTAssertGreaterThanOrEqual(hPastel, 1.15 * hPlain, "horizon b/r \(hPlain) → \(hPastel)")
        let zPlain = plain.zenith.x / plain.zenith.y, zPastel = pastel.zenith.x / pastel.zenith.y
        XCTAssertGreaterThanOrEqual(zPastel, 1.2 * zPlain, "zenith r/g \(zPlain) → \(zPastel)")
    }

    func testBlizzardDrivesTheSnowSideways() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let w = try XCTUnwrap(WeatherLayer(device: device))
        var s = frozen(13, weather: .blizzard)
        s.snow = 1; s.wind = 1; s.rain = 0
        s.gust = 1
        w.update(s, quality: .high, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, surface: .ground(horizonY: -0.33))
        XCTAssertGreaterThan(w.tilt, 1.2)
        XCTAssertGreaterThan(w.streamerCount, 0)
        XCTAssertLessThanOrEqual(w.streamerCount, 150)
        s.gust = 0
        w.update(s, quality: .high, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, surface: .ground(horizonY: -0.33))
        XCTAssertEqual(w.tilt, 0.25, accuracy: 0.01)
        XCTAssertEqual(w.streamerCount, 0)
        s.gust = 1
        w.update(s, quality: .lite, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, surface: .ground(horizonY: -0.33))
        XCTAssertLessThanOrEqual(w.streamerCount, 60, "Smooth keeps streamers light")
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

    /// Mean RGB (0…1) inside an NDC rectangle.
    static func meanRGB(_ image: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>) -> SIMD3<Double> {
        pixels(image, x: x, y: y).reduce(SIMD3<Double>(repeating: 0), +) / Double(max(1, pixels(image, x: x, y: y).count))
    }

    /// Mean luminance of the brightest `share` of the pixels inside an NDC rectangle.
    static func brightest(_ image: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>, share: Double = 0.05) -> Double {
        let l = pixels(image, x: x, y: y).map { 0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z }.sorted(by: >)
        let n = max(1, Int(Double(l.count) * share))
        return l.prefix(n).reduce(0, +) / Double(n)
    }

    static func pixels(_ image: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>) -> [SIMD3<Double>] {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out: [SIMD3<Double>] = []
        for row in 0..<h {
            let ny = 1 - 2 * (Double(row) + 0.5) / Double(h)
            guard y.contains(ny) else { continue }
            for col in 0..<w {
                let nx = 2 * (Double(col) + 0.5) / Double(w) - 1
                guard x.contains(nx) else { continue }
                let i = (row * w + col) * 4
                out.append(SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2])) / 255)
            }
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
    private func renderBeach(notes: [UInt8], at seconds: Double, state: ThemeState, width: Int = 640, height: Int = 360,
                             skyEdit: ((inout SkyState) -> Void)? = nil)
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
            if let edit = skyEdit, frame != nil { edit(&frame!.sky) }
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

    /// After the rain the whole beach is wet: the dry sand near the camera turns darker and mirrors the blue sky.
    func testBeachShinesAfterRain() throws {
        let state = ThemeState(values: ["keys.show": .bool(false)])
        let dry = try renderBeach(notes: [], at: 2, state: state) { $0.wetness = 0 }
        let wet = try renderBeach(notes: [], at: 2, state: state) { $0.wetness = 0.9 }
        let x = -0.33...0.33, y = -0.97 ... -0.86
        let a = FramePatch.meanRGB(dry.image, x: x, y: y), b = FramePatch.meanRGB(wet.image, x: x, y: y)
        let la = 0.2126 * a.x + 0.7152 * a.y + 0.0722 * a.z, lb = 0.2126 * b.x + 0.7152 * b.y + 0.0722 * b.z
        XCTAssertGreaterThanOrEqual(abs(lb - la) / max(la, 1e-6), 0.08, "dry \(a) wet \(b)")
        XCTAssertGreaterThan(b.z / max(b.x, 1e-6), 1.05 * a.z / max(a.x, 1e-6), "the wet sand reflects the sky: dry \(a) wet \(b)")
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
                           width: Int = 640, height: Int = 360, skyEdit: ((inout SkyState) -> Void)? = nil)
        throws -> (images: [CGImage], shots: [RoadShot], renderer: CoastRoadRenderer) {
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
            guard var f = d.step(dt: 1.0 / 60, t: t, quality: .high) as? RoadFrame else { continue }
            skyEdit?(&f.sky)
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

    /// Wet tarmac at night: the lights above the road shine back from it as streaks in the road strip.
    func testWetRoadReflectsTheLights() throws {
        let state = ThemeState(values: ["keys.show": .bool(false), "lamps": .number(1)])
        let notes: [UInt8] = [36, 40, 43, 48, 52, 55, 60, 64, 67, 72]
        let dry = try roadShots(notes: notes, at: [3], state: state, sky: MoonlitLakeRendererTests.night) { $0.wetness = 0 }
        let wet = try roadShots(notes: notes, at: [3], state: state, sky: MoonlitLakeRendererTests.night) { $0.wetness = 0.9 }
        // Keys hidden: the window's bottom is at −0.9 and the road strip runs to −0.84; the lights on the road sit
        // from −0.87 up, so the strip below them only shines by reflection.
        let x = -0.85...0.85, y = -0.895 ... -0.872
        let a = FramePatch.brightest(dry.images[0], x: x, y: y), b = FramePatch.brightest(wet.images[0], x: x, y: y)
        XCTAssertGreaterThanOrEqual(b, 1.3 * a, "dry \(a) wet \(b)")
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
        for (name, full) in [("road", CoastRoadShaders.source), ("beach", GoldenHourBeachShaders.source), ("ocean", OceanShaders.common),
                             ("sky", SkyShaders.source)] {
            let source = name == "ocean" || name == "sky" ? full : String(full.dropFirst(shared))
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
            ("lake-after-rain", sky(hour: 22, phase: 0.55, weather: .afterRain), .high, 5),
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
            ("beach-after-rain", sky(hour: 13, phase: 0.5, weather: .afterRain), held, .high, 5),
            ("beach-blizzard", sky(hour: 13, phase: 0.5, weather: .blizzard), held, .high, 5),
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
            ("road-after-rain-night", sky(hour: 1, phase: 0.5, weather: .afterRain), follow, .high, 5),
            ("road-blizzard", sky(hour: 13, phase: 0.5, weather: .blizzard), held, .high, 5),
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
            ("sky-blizzard-ground", 13.0, 0.5, .blizzard, .ground(horizonY: -0.33)),
            ("sky-after-rain-ground", 9.5, 0.5, .afterRain, .ground(horizonY: -0.33)),
            ("sky-sun-shower-rainbow", 16.6, 0.5, .sunShower, .ground(horizonY: -0.33)),
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
        // Optics: halos, sundogs, a moon halo, a pastel dawn and the Belt of Venus (held or placed to show them).
        let zone = TimeZone(identifier: "Australia/Melbourne")!
        func state(hour: Double, phase: Double, weather: WeatherKind, hold: SkyHold = .follow) -> SkyState {
            var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
            s.weatherMode = .pick; s.weather = weather
            let sky = LivingSky(settings: s, homeZone: zone)
            var st = sky.step(now: Date(timeIntervalSince1970: 1_793_000_000), dt: 0, hold: hold)
            for i in 1...120 { st = sky.step(now: Date(timeIntervalSince1970: 1_793_000_000 + Double(i)), dt: 1, hold: hold) }
            return st
        }
        var haloDay = state(hour: 13, phase: 0.5, weather: .lightCloud); haloDay.halo = 1
        var lowSun = state(hour: 13, phase: 0.5, weather: .clear); lowSun.halo = 1
        let ahead = SkyLayer.defaultViewAzimuth(latitude: lowSun.latitude)
        lowSun.sun = SkyDirection(azimuth: ahead, altitude: 8)
        let lowColours = SkyPalette.colours(sunAltitude: 8, cloud: 0, mist: lowSun.mist, moonlight: 0)
        lowSun.zenith = lowColours.zenith; lowSun.horizon = lowColours.horizon
        var moonHalo = state(hour: 23.5, phase: 0.5, weather: .lightCloud); moonHalo.halo = 1
        moonHalo.moon = SkyDirection(azimuth: ahead, altitude: 30); moonHalo.moonLit = 1
        let pastel = state(hour: 13, phase: 0.5, weather: .lightCloud, hold: .pastelDawn)
        var belt = state(hour: 13, phase: 0.5, weather: .clear)
        belt.sun = SkyDirection(azimuth: ahead + 180, altitude: -3)
        let beltColours = SkyPalette.colours(sunAltitude: -3, cloud: 0, mist: belt.mist, moonlight: 0)
        belt.zenith = beltColours.zenith; belt.horizon = beltColours.horizon; belt.starVisibility = 0.1
        let optics: [(String, SkyState, Double?)] = [
            ("sky-halo-day", haloDay, nil), ("sky-sundogs-low", lowSun, ahead), ("sky-moon-halo", moonHalo, ahead),
            ("sky-pastel-dawn", pastel, pastel.sun.azimuth), ("sky-belt-of-venus", belt, ahead),
        ]
        for (name, st, view) in optics {
            let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
            r.sky.viewAzimuth = view
            for i in 0..<10 { r.update(st, quality: .high, size: CGSize(width: 1280, height: 720), dt: 1.0 / 30, time: Float(i) / 30, surface: .none) }
            let image = try XCTUnwrap(preview.capture(r))
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
    }
}

/// Snowbound Cabin Window (Set 5's world) with Frost Grow and the Window Kit.
@MainActor
final class SnowboundCabinRendererTests: XCTestCase {
    func testCabinShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: SnowboundCabinShaders.source, options: nil)
        for name in ["cabin_glass_vertex", "cabin_full_vertex", "cabin_scene_fragment", "cabin_spark_vertex", "cabin_spark_fragment",
                     "cabin_room_fragment", "cabin_keys_vertex", "cabin_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
        let own = String(SnowboundCabinShaders.source.dropFirst(SkyShaders.common.count))
        XCTAssertFalse(own.contains("pow("), "squares and powers are written out")
    }

    nonisolated static func sky(hour: Double, weather: WeatherKind = .clear, phase: Double = 0.5) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = weather
        return s
    }

    struct CabinShot { var image: CGImage; var renderer: SnowboundCabinRenderer; var frame: CabinFrame }

    /// Steps the cabin at 60 fps (notes go down at `noteTime` and stay held) and renders the frame at `seconds`.
    private func renderCabin(notes: [UInt8], velocity: Float = 1, noteTime: Double = 0.5, at seconds: Double,
                             state: ThemeState = ThemeState(), sky: SkySettings = SnowboundCabinRendererTests.sky(hour: 22),
                             quality: QualityLevel = .high,
                             gentle: Bool = false, width: Int = 640, height: Int = 360,
                             each: ((SnowboundCabinRenderer, CabinFrame) -> Void)? = nil) throws -> CabinShot {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(SnowboundCabinRenderer(device: device))
        XCTAssertTrue(r.awaitField(), "the frost field grows")
        let d = SceneDirector(themeID: SnowboundCabinModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky)
        var frame: CabinFrame?
        let size = CGSize(width: width, height: height)
        let noteStep = Int((noteTime * 60).rounded())
        for i in 1...Int(seconds * 60) {
            let t = Double(i) / 60
            elapsed = t
            if i == max(1, noteStep), !notes.isEmpty { d.handle(notes.map { .noteOn(note: $0, velocity: velocity) }, at: t) }
            frame = d.step(dt: 1.0 / 60, t: t, quality: quality) as? CabinFrame
            if let frame {
                r.update(frame, params: d.parameters, quality: quality, gentle: gentle, dt: 1.0 / 60, size: size)
                each?(r, frame)
            }
        }
        let f = try XCTUnwrap(frame)
        return CabinShot(image: try XCTUnwrap(preview.capture(r)), renderer: r, frame: f)
    }

    func testCabinPreviewIsStructured() throws {
        for q in [QualityLevel.lite, .high] {
            for hour in [22.0, 18.9, 13.0] {
                let shot = try renderCabin(notes: [], at: 1, sky: Self.sky(hour: hour), quality: q)
                let s = PreviewRenderer.stats(shot.image)
                XCTAssertGreaterThan(s.meanLuminance, 0.02, "\(q) \(hour)")
                XCTAssertGreaterThan(s.variance, 0.002, "\(q) \(hour)")
            }
        }
    }

    func testFrostGrowsOnTheCabinGlass() throws {
        let held = try renderCabin(notes: [48, 52, 55, 59], velocity: 0.5, at: 30)
        let silent = try renderCabin(notes: [], at: 30)
        XCTAssertGreaterThanOrEqual(held.renderer.glass.frostCoverage - silent.renderer.glass.frostCoverage, 0.15)
        XCTAssertGreaterThan(held.frame.frostLevel, silent.frame.frostLevel)
    }

    /// The share of pixels in an NDC box whose luminance differs from the frost-free render by more than 0.05.
    private func frosted(_ a: CGImage, _ bare: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>) -> Double {
        let pa = FramePatch.pixels(a, x: x, y: y), pb = FramePatch.pixels(bare, x: x, y: y)
        func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        var n = 0
        for i in 0..<min(pa.count, pb.count) where abs(luma(pa[i]) - luma(pb[i])) > 0.05 { n += 1 }
        return pa.isEmpty ? 0 : Double(n) / Double(pa.count)
    }

    func testNotesMeltPatches() throws {
        // A snowy night (plenty of frost); one note held from 0.5 s melts a clear patch where its key sits.
        let night = Self.sky(hour: 22, weather: .snow)
        let shot = try renderCabin(notes: [60], velocity: 0.6, at: 5, sky: night)
        let bare = try renderCabin(notes: [60], velocity: 0.6, at: 5, state: ThemeState(values: ["frost": .number(0)]), sky: night)
        let patch = try XCTUnwrap(shot.frame.patches.first)
        let rect = shot.renderer.windowRect
        let cx = Double(rect.x + (rect.z - rect.x) * patch.x), cy = Double(rect.y + (rect.w - rect.y) * patch.y)
        let ry = Double(patch.radius * (rect.w - rect.y)), rx = ry * 360 / 640
        let inside = frosted(shot.image, bare.image, x: (cx - 0.5 * rx)...(cx + 0.5 * rx), y: (cy - 0.5 * ry)...(cy + 0.5 * ry))
        let around = (frosted(shot.image, bare.image, x: (cx - 2.6 * rx)...(cx - 1.6 * rx), y: (cy - 0.5 * ry)...(cy + 0.5 * ry))
                      + frosted(shot.image, bare.image, x: (cx + 1.6 * rx)...(cx + 2.6 * rx), y: (cy - 0.5 * ry)...(cy + 0.5 * ry))) / 2
        XCTAssertLessThan(inside, around - 0.2, "inside \(inside), around \(around)")
    }

    func testCabinHonoursGentleVisuals() throws {
        var plain: (flare: Float, glint: Float) = (0, 0), gentle: (flare: Float, glint: Float) = (0, 0)
        _ = try renderCabin(notes: [60, 64, 67], at: 0.8) { r, _ in plain = (max(plain.flare, r.flareOut), max(plain.glint, r.glintOut)) }
        _ = try renderCabin(notes: [60, 64, 67], at: 0.8, gentle: true) { r, _ in
            gentle = (max(gentle.flare, r.flareOut), max(gentle.glint, r.glintOut))
        }
        XCTAssertGreaterThan(plain.flare, 0.3, "a chord flares the fire")
        XCTAssertLessThanOrEqual(gentle.flare, plain.flare * 0.55)
        XCTAssertLessThanOrEqual(gentle.glint, plain.glint * 0.55)
    }

    func testNoRainInsideTheCabin() throws {
        let shot = try renderCabin(notes: [], at: 5, sky: Self.sky(hour: 22, weather: .rain))
        XCTAssertEqual(shot.frame.sky.rain, 0)
        XCTAssertGreaterThan(shot.frame.sky.snow, 0.5)
        XCTAssertEqual(shot.renderer.weather.kind, 1, "snow, never rain streaks")
        XCTAssertGreaterThan(shot.renderer.weather.particleCount, 0)
        XCTAssertGreaterThan(shot.renderer.glass.stuckFlakeCount, 0, "flakes land on the glass")
    }

    func testCabinFramesAnyAspect() throws {
        for (w, h) in [(864, 360), (360, 360)] {
            let shot = try renderCabin(notes: [60, 64, 67], at: 1, width: w, height: h)
            let r = shot.renderer.windowRect
            let aspect = Float(w) / Float(h)
            XCTAssertGreaterThanOrEqual(r.x - 0.05, -1, "\(w)×\(h)"); XCTAssertLessThanOrEqual(r.z + 0.05, 1, "\(w)×\(h)")
            XCTAssertGreaterThanOrEqual(r.y, -1, "\(w)×\(h)"); XCTAssertLessThanOrEqual(r.w + 0.05 * aspect, 1, "\(w)×\(h)")
            XCTAssertEqual(shot.renderer.keyRects.count, 88)
            for k in shot.renderer.keyRects {
                XCTAssertGreaterThanOrEqual(k.x, -1); XCTAssertLessThanOrEqual(k.z, 1)
                XCTAssertGreaterThanOrEqual(k.y, -1); XCTAssertLessThanOrEqual(k.w, 1)
            }
            let s = PreviewRenderer.stats(shot.image)
            XCTAssertGreaterThan(s.variance, 0.001, "\(w)×\(h)")
        }
    }

    func testCabinBurstStaysInBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(SnowboundCabinRenderer(device: device))
        let d = SceneDirector(themeID: SnowboundCabinModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        d.sky.reset(settings: Self.sky(hour: 22))
        for q in [QualityLevel.lite, .high] {
            let start = Date()
            for i in 0..<60 {
                let t = Double(i) / 60
                if i < 60 { d.handle((0..<34).map { k in .noteOn(note: UInt8(21 + (i * 34 + k) % 88), velocity: 0.8) }, at: t) }
                let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: q) as? CabinFrame)
                r.update(f, params: d.parameters, quality: q, gentle: false, dt: 1.0 / 60, size: CGSize(width: 640, height: 360))
                XCTAssertLessThanOrEqual(r.patchCount, SnowboundCabinRenderer.patchBudget(q))
                XCTAssertNotNil(preview.capture(r))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 4, "\(q)")
        }
    }
}

extension WorldPreviewTests {
    func testWriteCabinPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let follow = ThemeState()
        let pastel = ThemeState(values: ["light.hold": .choice(SkyHold.pastelDawn.rawValue)])
        let golden = ThemeState(values: ["light.hold": .choice(SkyHold.goldenHour.rawValue)])
        let warp = ThemeState(values: ["visual": .choice("Galaxy Warp")])
        let sky = SnowboundCabinRendererTests.sky
        let cases: [(String, SkySettings, ThemeState, QualityLevel, Double)] = [
            ("cabin-night", sky(22, .clear, 0.5), follow, .high, 5),
            ("cabin-golden", sky(13, .clear, 0.5), golden, .high, 5),
            ("cabin-noon-halo", sky(13, .lightCloud, 0.5), follow, .high, 5),
            ("cabin-pastel-dawn", sky(13, .lightCloud, 0.5), pastel, .high, 5),
            ("cabin-blizzard", sky(15, .blizzard, 0.5), follow, .high, 5),
            ("cabin-snow", sky(21, .snow, 0.5), follow, .high, 5),
            ("cabin-smooth", sky(22, .clear, 0.5), follow, .lite, 5),
            ("cabin-frost-t30", sky(22, .clear, 0.5), follow, .high, 30),
            ("cabin-warp-t7", sky(22, .clear, 0.5), warp, .high, 7),
        ]
        for (name, s, state, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: SnowboundCabinModel.id, at: [t], state: state, quality: q, sky: s,
                                                     mood: .hushedWarm).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
    }
}

/// Bedroom Window at Dawn (Set 6's world) with Curtain Light and the Window Kit.
@MainActor
final class BedroomDawnRendererTests: XCTestCase {
    func testBedroomShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: BedroomDawnShaders.source, options: nil)
        for name in ["bed_glass_vertex", "bed_full_vertex", "bed_scene_fragment", "bed_room_fragment", "bed_shaft_fragment",
                     "bed_curtain_vertex", "bed_curtain_fragment", "bed_sprite_vertex", "bed_sprite_fragment",
                     "bed_keys_vertex", "bed_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
        let own = String(BedroomDawnShaders.source.dropFirst(SkyShaders.common.count))
        XCTAssertFalse(own.contains("pow("), "squares and powers are written out")
    }

    nonisolated static func sky(hour: Double, weather: WeatherKind = .clear, phase: Double = 0.5) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = weather
        return s
    }

    struct BedroomShot { var image: CGImage; var renderer: BedroomDawnRenderer; var frame: BedroomFrame }

    /// Steps the bedroom at 60 fps (notes go down at 0.5 s and stay held) and renders the frame at `seconds`.
    private func renderBedroom(notes: [UInt8], at seconds: Double, state: ThemeState = ThemeState(),
                               sky: SkySettings = BedroomDawnRendererTests.sky(hour: 13), quality: QualityLevel = .high,
                               gentle: Bool = false, width: Int = 640, height: Int = 360,
                               skyEdit: ((inout SkyState) -> Void)? = nil,
                               each: ((BedroomDawnRenderer, BedroomFrame) -> Void)? = nil) throws -> BedroomShot {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(BedroomDawnRenderer(device: device))
        XCTAssertTrue(r.awaitField())
        let d = SceneDirector(themeID: BedroomDawnModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky)
        var frame: BedroomFrame?
        let size = CGSize(width: width, height: height)
        for i in 1...Int(seconds * 60) {
            let t = Double(i) / 60
            elapsed = t
            if i == 30, !notes.isEmpty { d.handle(notes.map { .noteOn(note: $0, velocity: 0.8) }, at: t) }
            frame = d.step(dt: 1.0 / 60, t: t, quality: quality) as? BedroomFrame
            if let edit = skyEdit, frame != nil { edit(&frame!.sky) }
            if let frame {
                r.update(frame, params: d.parameters, quality: quality, gentle: gentle, dt: 1.0 / 60, size: size)
                each?(r, frame)
            }
        }
        let f = try XCTUnwrap(frame)
        return BedroomShot(image: try XCTUnwrap(preview.capture(r)), renderer: r, frame: f)
    }

    private func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    func testBedroomPreviewIsStructured() throws {
        let pastel = ThemeState()
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        for q in [QualityLevel.lite, .high] {
            for (state, hour) in [(pastel, 13.0), (follow, 13.0), (follow, 20.3), (follow, 23.0)] {
                let shot = try renderBedroom(notes: [], at: 1, state: state, sky: Self.sky(hour: hour), quality: q)
                let s = PreviewRenderer.stats(shot.image)
                XCTAssertGreaterThan(s.meanLuminance, 0.02, "\(q) \(hour)")
                XCTAssertGreaterThan(s.variance, 0.002, "\(q) \(hour)")
            }
        }
    }

    /// The floor below the window, in NDC.
    private func floorBox(_ r: BedroomDawnRenderer) -> (ClosedRange<Double>, ClosedRange<Double>) {
        let rect = r.windowRect
        return (Double(rect.x - 0.3)...Double(rect.z + 0.3), Double(r.floorLine - 0.16)...Double(r.floorLine - 0.02))
    }

    func testHoldingNotesBrightensTheRoom() throws {
        let held = try renderBedroom(notes: [60, 64, 67, 71], at: 4.5)
        let silent = try renderBedroom(notes: [], at: 4.5)
        let (x, y) = floorBox(held.renderer)
        let a = luma(FramePatch.meanRGB(held.image, x: x, y: y)), b = luma(FramePatch.meanRGB(silent.image, x: x, y: y))
        XCTAssertGreaterThanOrEqual(a, 1.15 * b, "held \(a), silent \(b)")
    }

    func testShaftsFallThroughThePanes() throws {
        // The same dawn with and without Morning light: the difference is the shafts (and the floor patch).
        let shot = try renderBedroom(notes: [], at: 1, state: ThemeState(values: ["light": .number(1)]))
        let dark = try renderBedroom(notes: [], at: 1, state: ThemeState(values: ["light": .number(0)]))
        XCTAssertGreaterThan(shot.renderer.shaftOut, 0.05, "the dawn sun shines in")
        XCTAssertEqual(dark.renderer.shaftOut, 0)
        let r = shot.renderer
        let pane = try XCTUnwrap(r.glassPanesNDC().min { ($0.y, -$0.x) < ($1.y, -$1.x) })   // the bottom-right pane
        let centre = SIMD2<Float>((pane.x + pane.z) / 2, (pane.y + pane.w) / 2)
        let dir = r.beamDirection
        var perp = SIMD2<Float>(-dir.y, dir.x)
        if perp.x < 0 { perp = -perp }
        let along = centre + dir * 0.25
        let side = along + perp * 0.3
        func gain(_ p: SIMD2<Float>) -> Double {
            let x = Double(p.x - 0.015)...Double(p.x + 0.015), y = Double(p.y - 0.015)...Double(p.y + 0.015)
            return luma(FramePatch.meanRGB(shot.image, x: x, y: y)) - luma(FramePatch.meanRGB(dark.image, x: x, y: y))
        }
        XCTAssertGreaterThan(gain(along), gain(side) + 0.01, "a beam below the pane, not beside it")
    }

    func testBedroomHonoursGentleVisuals() throws {
        var plain: (glint: Float, glow: Float) = (0, 0), gentle: (glint: Float, glow: Float) = (0, 0)
        _ = try renderBedroom(notes: [72, 84, 96], at: 3) { r, _ in plain = (max(plain.glint, r.glintOut), max(plain.glow, r.glowOut)) }
        _ = try renderBedroom(notes: [72, 84, 96], at: 3, gentle: true) { r, _ in gentle = (max(gentle.glint, r.glintOut), max(gentle.glow, r.glowOut)) }
        XCTAssertGreaterThan(plain.glow, 0.3)
        XCTAssertLessThanOrEqual(gentle.glint, plain.glint * 0.55)
        XCTAssertLessThanOrEqual(gentle.glow, plain.glow * 0.55)
    }

    func testStreetShinesAfterRain() throws {
        let night = BedroomDawnRendererTests.sky(hour: 22)
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        let wet = try renderBedroom(notes: [], at: 1, state: follow, sky: night) { $0.wetness = 0.9 }
        let dry = try renderBedroom(notes: [], at: 1, state: follow, sky: night) { $0.wetness = 0 }
        let rect = wet.renderer.windowRect
        let h = Double(rect.w - rect.y)
        let x = Double(rect.x + 0.02)...Double(rect.z - 0.02)
        let y = (Double(rect.y) + 0.12 * h)...(Double(rect.y) + 0.3 * h)
        let pw = FramePatch.pixels(wet.image, x: x, y: y).map(luma), pd = FramePatch.pixels(dry.image, x: x, y: y).map(luma)
        func variance(_ v: [Double]) -> Double { let m = v.reduce(0, +) / Double(max(1, v.count)); return v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(max(1, v.count)) }
        let mw = pw.reduce(0, +) / Double(max(1, pw.count)), md = pd.reduce(0, +) / Double(max(1, pd.count))
        XCTAssertGreaterThan(mw + variance(pw) * 10, md + variance(pd) * 10, "wet \(mw) dry \(md)")
    }

    func testBedroomFramesAnyAspect() throws {
        for (w, h) in [(864, 360), (360, 360)] {
            let shot = try renderBedroom(notes: [60, 64, 67], at: 1.5, width: w, height: h)
            let r = shot.renderer
            let aspect = Float(w) / Float(h)
            XCTAssertGreaterThanOrEqual(r.windowRect.x - 0.045, -1, "\(w)×\(h)")
            XCTAssertLessThanOrEqual(r.windowRect.z + 0.045, 1, "\(w)×\(h)")
            XCTAssertLessThanOrEqual(r.windowRect.w + 0.045 * aspect, 1, "\(w)×\(h)")
            XCTAssertEqual(r.curtainPoints.count, 2 * 24 * 32)
            for p in r.curtainPoints { XCTAssertTrue((-1...1).contains(p.x) && (-1...1).contains(p.y)) }
            XCTAssertEqual(r.keyRects.count, 88)
            for k in r.keyRects {
                XCTAssertGreaterThanOrEqual(k.x, -1); XCTAssertLessThanOrEqual(k.z, 1)
                XCTAssertGreaterThanOrEqual(k.y, -1); XCTAssertLessThanOrEqual(k.w, 1)
            }
            XCTAssertGreaterThan(r.shaftOut, 0.05, "\(w)×\(h): the shafts still fall")
            XCTAssertGreaterThan(r.floorLine, -1, "\(w)×\(h): the floor is in view")
            XCTAssertGreaterThan(PreviewRenderer.stats(shot.image).variance, 0.001)
        }
    }

    /// Following the sky on a summer afternoon, the sun sinking through 25° in the west doesn't swing the view round
    /// from east (final review: it turned about 170° whenever the sun crossed 25° or −12°).
    func testBedroomViewNeverSwingsRound() throws {
        var frameIndex = 0
        var azimuths: [Double] = []
        _ = try renderBedroom(notes: [], at: 4, state: ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)]),
                              skyEdit: { s in
                                  frameIndex += 1
                                  s.sun = SkyDirection(azimuth: 280, altitude: 26 - 2 * Double(frameIndex) / 240)
                              },
                              each: { r, _ in if let az = r.viewAzimuth { azimuths.append(az) } })
        let first = try XCTUnwrap(azimuths.first), last = try XCTUnwrap(azimuths.last)
        let turn = abs((last - first + 540).truncatingRemainder(dividingBy: 360) - 180)
        XCTAssertLessThan(turn, 45, "turned \(turn)°")
    }

    /// The shafts and the panes stop at the window's real bars instead of walking all 19 slots for every sample of
    /// every pixel (final review: about 133 loop steps per pixel on Smooth).
    func testBarLoopsStopAtTheBars() {
        for (name, source) in [("bedroom", BedroomDawnShaders.source), ("cabin", SnowboundCabinShaders.source)] {
            XCTAssertTrue(source.contains("if (i >= nBars) break;"), name)
        }
        XCTAssertTrue(BedroomDawnShaders.source.contains("discard_fragment();   // outside every beam"), "the shaft pass skips pixels no beam can reach")
    }

    func testBedroomBurstStaysInBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(BedroomDawnRenderer(device: device))
        let d = SceneDirector(themeID: BedroomDawnModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        d.sky.reset(settings: Self.sky(hour: 13))
        for q in [QualityLevel.lite, .high] {
            let start = Date()
            for i in 0..<60 {
                let t = Double(i) / 60
                d.handle((0..<34).map { k in .noteOn(note: UInt8(21 + (i * 34 + k) % 88), velocity: 0.8) }, at: t)
                let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: q) as? BedroomFrame)
                r.update(f, params: d.parameters, quality: q, gentle: false, dt: 1.0 / 60, size: CGSize(width: 640, height: 360))
                XCTAssertEqual(r.curtainVertexCount, 2 * 24 * 32)
                XCTAssertNotNil(preview.capture(r))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 4, "\(q)")
        }
        XCTAssertLessThanOrEqual(r.bufferAllocations, 3, "curtain vertices and sprites reuse a ring of three")
    }
}

extension WorldPreviewTests {
    func testWriteBedroomPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let pastel = ThemeState()
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        let golden = ThemeState(values: ["light.hold": .choice(SkyHold.goldenHour.rawValue)])
        let frost = ThemeState(values: ["visual": .choice("Frost Grow"), "light.hold": .choice(SkyHold.follow.rawValue)])
        let open = ThemeState(values: ["window.open": .bool(true)])
        let sky = BedroomDawnRendererTests.sky
        let cases: [(String, SkySettings, ThemeState, QualityLevel, Double)] = [
            ("bedroom-pastel-dawn", sky(13, .clear, 0.5), pastel, .high, 5),
            ("bedroom-golden", sky(13, .clear, 0.5), golden, .high, 5),
            ("bedroom-noon", sky(12.5, .lightCloud, 0.5), follow, .high, 5),
            ("bedroom-night-fairy", sky(22.5, .clear, 0.5), follow, .high, 5),
            ("bedroom-after-rain", sky(8.5, .afterRain, 0.5), follow, .high, 5),
            ("bedroom-rain", sky(9, .rain, 0.5), follow, .high, 5),
            ("bedroom-snow", sky(7.5, .snow, 0.5), follow, .high, 5),
            ("bedroom-smooth", sky(13, .clear, 0.5), pastel, .lite, 5),
            ("bedroom-light-t4", sky(13, .clear, 0.5), pastel, .high, 4),
            ("bedroom-frost-t20", sky(6.5, .snow, 0.5), frost, .high, 20),
            ("bedroom-window-open", sky(13, .clear, 0.5), open, .high, 5),
        ]
        for (name, s, state, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: BedroomDawnModel.id, at: [t], state: state, quality: q, sky: s,
                                                     mood: .softWaking).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
    }
}
