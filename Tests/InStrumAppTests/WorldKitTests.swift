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
        // The Swift rows match the MSL SkyU byte for byte, the `still` row last (the pipeline's own reflection says so).
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "sky_dome_vertex")
        d.fragmentFunction = lib.makeFunction(name: "sky_dome_fragment")
        d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
        var reflection: MTLAutoreleasedRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
        let skyU = (reflection?.fragmentBindings ?? []).compactMap { $0 as? MTLBufferBinding }.first { $0.index == 0 }
        XCTAssertEqual(skyU?.bufferDataSize, SkyLayer.uniformCount * MemoryLayout<SIMD4<Float>>.stride, "SkyU")
        XCTAssertEqual(SkyLayer.stillRow, SkyLayer.uniformCount - 1)
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

    // MARK: - The aurora, real stars and constellation lines, light pillars, fireflies and diamond dust

    /// An equatorial unit vector (RA, Dec in degrees) turned into east-north-up with the shader's own basis (the
    /// transpose of `eq`, whose columns are east, north and up in equatorial coordinates).
    private func enu(ra: Float, dec: Float, _ s: SkyState) -> SIMD3<Float> {
        let a = Double(ra) * .pi / 180, d = Double(dec) * .pi / 180
        let v = SIMD3<Float>(Float(cos(d) * cos(a)), Float(cos(d) * sin(a)), Float(sin(d)))
        let b = SkyLayer.equatorialBasis(siderealDegrees: s.siderealDegrees, latitude: s.latitude)
        return SIMD3(simd_dot(v, b.east), simd_dot(v, b.north), simd_dot(v, b.up))
    }

    /// Points the sky's camera straight at an east-north-up direction (it lands at the frame's centre).
    private func aim(_ sky: SkyLayer, at e: SIMD3<Float>) {
        let alt = asin(Double(min(1, max(-1, e.z))))
        sky.viewAzimuth = atan2(Double(e.x), Double(e.y)) * 180 / .pi
        sky.horizonY = Float(-tan(alt) / tan(sky.verticalFOV * .pi / 360))
    }

    /// The NDC point of an east-north-up direction through the sky's camera.
    private func screenPoint(_ d: SIMD3<Float>, sky: SkyLayer, latitude: Double) -> (x: Double, y: Double) {
        let cam = sky.camera(latitude: latitude, aspect: 640.0 / 360)
        let f = simd_dot(d, cam.forward)
        return (Double(simd_dot(d, cam.right) / f / cam.tanH), Double(simd_dot(d, cam.up) / f / cam.tanV))
    }

    /// Renders a forced state with the sky's camera set up by `configure` (surface none, so the horizon stays put).
    private func renderConfigured(_ state: SkyState, time: Float = 0,
                                  _ configure: (SkyOnlyRenderer) -> Void) throws -> (image: CGImage, sky: SkyLayer) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
        configure(r)
        r.update(state, quality: .high, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, time: time, surface: .none)
        return (try XCTUnwrap(preview.capture(r)), r.sky)
    }

    /// A clear, moonless night at Melbourne with every new sky value zeroed (tests switch on the one they need).
    private func darkNight() -> SkyState {
        var s = frozen(2)
        s.sun = SkyDirection(azimuth: 0, altitude: -40)
        s.moon = SkyDirection(azimuth: 0, altitude: -30); s.moonLit = 0
        let c = SkyPalette.colours(sunAltitude: -40, cloud: 0, mist: 0, moonlight: 0)
        s.zenith = c.zenith; s.horizon = c.horizon
        s.starVisibility = 1; s.cloudCover = 0; s.mist = 0; s.halo = 0; s.rainbow = 0
        s.aurora = 0; s.auroraStorm = 0; s.auroraAltitude = 0; s.fireflies = 0; s.diamondDust = 0; s.pillar = 0
        s.constellationLines = 0
        return s
    }

    /// Tromsø-like: the band's base 45° up toward the pole. Looking pole-ward, the sky 30–60° up is far brighter with the
    /// aurora on; facing away it is unchanged.
    func testAuroraLightsThePoleSky() throws {
        var s = darkNight()
        s.latitude = 69.6; s.hemisphere = 1; s.auroraAltitude = 45; s.auroraStorm = 0.3
        func patch(aurora: Float, view: Double) throws -> Double {
            var st = s; st.aurora = aurora
            let (image, sky) = try renderConfigured(st) { r in
                r.sky.viewAzimuth = view
                r.sky.horizonY = Float(-tan(45 * Double.pi / 180) / tan(r.sky.verticalFOV * .pi / 360))   // looking 45° up
            }
            let lo = screenPoint(SkyDirection(azimuth: view, altitude: 32), sky: sky, latitude: st.latitude).y
            let hi = screenPoint(SkyDirection(azimuth: view, altitude: 58), sky: sky, latitude: st.latitude).y
            return luma(FramePatch.meanRGB(image, x: -0.3...0.3, y: lo...hi))
        }
        let poleOn = try patch(aurora: 1, view: 0), poleOff = try patch(aurora: 0, view: 0)
        XCTAssertGreaterThanOrEqual(poleOn, 1.4 * poleOff, "pole-ward \(poleOff) → \(poleOn)")
        let awayOn = try patch(aurora: 1, view: 180), awayOff = try patch(aurora: 0, view: 180)
        XCTAssertEqual(awayOn, awayOff, accuracy: max(0.1 * awayOff, 0.5 / 255), "facing away \(awayOff) → \(awayOn)")
        // In the south the band lies the other way.
        var south = s; south.latitude = -60; south.hemisphere = -1; south.aurora = 1
        let (image, sky) = try renderConfigured(south) { r in
            r.sky.viewAzimuth = 180
            r.sky.horizonY = Float(-tan(45 * Double.pi / 180) / tan(r.sky.verticalFOV * .pi / 360))
        }
        let lo = screenPoint(SkyDirection(azimuth: 180, altitude: 32), sky: sky, latitude: -60).y
        let hi = screenPoint(SkyDirection(azimuth: 180, altitude: 58), sky: sky, latitude: -60).y
        XCTAssertGreaterThanOrEqual(luma(FramePatch.meanRGB(image, x: -0.3...0.3, y: lo...hi)), 1.4 * poleOff, "australis")
    }

    /// Sirius from Melbourne, 37° up: its screen point (from its catalogue RA/Dec through the shader's basis and the
    /// sky's camera) is among the brightest 0.1% of the frame; with no stars it is just sky.
    func testRealStarsShow() throws {
        let sirius = try XCTUnwrap(StarCatalogue.star(hip: 32349))
        var s = darkNight()
        s.siderealDegrees = Double(sirius.ra) + 55   // 55° past the meridian
        let e = enu(ra: sirius.ra, dec: sirius.dec, s)
        XCTAssertGreaterThan(asin(Double(e.z)) * 180 / .pi, 30, "Sirius is well up")
        func peak(visibility: Float) throws -> (local: Double, top: Double) {
            var st = s; st.starVisibility = visibility
            let (image, sky) = try renderConfigured(st) { r in
                XCTAssertTrue(r.sky.awaitStars(), "the star texture arrives")
                aim(r.sky, at: e)
            }
            let p = screenPoint(e, sky: sky, latitude: st.latitude)
            let l = FramePatch.luminance(image)
            let w = image.width, h = image.height
            let cx = Int((p.x + 1) / 2 * Double(w)), cy = Int((1 - p.y) / 2 * Double(h))
            var local = 0.0
            for y in max(0, cy - 3)...min(h - 1, cy + 3) { for x in max(0, cx - 3)...min(w - 1, cx + 3) { local = max(local, l[y * w + x]) } }
            let sorted = l.sorted(by: >)
            return (local, sorted[max(0, sorted.count / 1000 - 1)])
        }
        let on = try peak(visibility: 1)
        XCTAssertGreaterThanOrEqual(on.local, on.top, "Sirius \(on.local) against the top 0.1% \(on.top)")
        XCTAssertGreaterThan(on.local, 0.5)
        let off = try peak(visibility: 0)
        XCTAssertLessThan(off.local, 0.2, "no stars: \(off.local)")
    }

    /// The Acrux–Gacrux line: its midpoint is brighter with the lines on; with them off the frame matches one drawn
    /// from a texture that has no lines at all.
    func testConstellationLinesCanBeTurnedOff() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let acrux = try XCTUnwrap(StarCatalogue.star(hip: 60718)), gacrux = try XCTUnwrap(StarCatalogue.star(hip: 61084))
        var s = darkNight()
        s.siderealDegrees = Double(acrux.ra + gacrux.ra) / 2 + 40
        let mid = simd_normalize(enu(ra: acrux.ra, dec: acrux.dec, s) + enu(ra: gacrux.ra, dec: gacrux.dec, s))
        XCTAssertGreaterThan(asin(Double(mid.z)) * 180 / .pi, 20, "Crux is up")
        let bare = try XCTUnwrap(StarTextureCache.makeTexture(device: device, bytes: StarTexture.build(lines: false)))
        let a = enu(ra: acrux.ra, dec: acrux.dec, s), b = enu(ra: gacrux.ra, dec: gacrux.dec, s)
        func frame(lines: Float, texture: MTLTexture? = nil) throws -> (image: CGImage, sky: SkyLayer) {
            var st = s; st.constellationLines = lines
            return try renderConfigured(st) { r in
                XCTAssertTrue(r.sky.awaitStars())
                r.sky.starTextureOverride = texture
                aim(r.sky, at: mid)
            }
        }
        let on = try frame(lines: 1), off = try frame(lines: 0), noLines = try frame(lines: 1, texture: bare)
        // The line's middle stretch (35–65% of the way from Acrux to Gacrux): at nine points along it, the brightest
        // pixel within 2 px (the line is a pixel or two wide); the median ignores any star that happens to sit there.
        func lineLight(_ f: (image: CGImage, sky: SkyLayer)) -> Double {
            let l = FramePatch.luminance(f.image), w = f.image.width, h = f.image.height
            var samples: [Double] = []
            for i in 0..<9 {
                let t = Float(0.35 + 0.3 * Double(i) / 8)
                let p = screenPoint(simd_normalize(a * (1 - t) + b * t), sky: f.sky, latitude: s.latitude)
                let cx = Int((p.x + 1) / 2 * Double(w)), cy = Int((1 - p.y) / 2 * Double(h))
                var best = 0.0
                for y in max(0, cy - 2)...min(h - 1, cy + 2) { for x in max(0, cx - 2)...min(w - 1, cx + 2) { best = max(best, l[y * w + x]) } }
                samples.append(best)
            }
            return samples.sorted()[4]
        }
        let lOn = lineLight(on), lOff = lineLight(off)
        XCTAssertGreaterThanOrEqual(lOn, 1.15 * lOff, "along the line \(lOff) → \(lOn)")
        let diff = FramePatch.difference(off.image, noLines.image, x: -1...1, y: -1...1)
        let mean = PreviewRenderer.stats(noLines.image).meanLuminance
        XCTAssertLessThanOrEqual(diff, max(0.02 * mean, 0.5 / 255), "lines 0 leaves no trace: \(diff)")
    }

    /// Diamond dust with the sun 4° up: a column stands 6° above it, brighter than the sky 6° beside the column.
    func testPillarsStandOverTheLowSun() throws {
        var s = frozen(13)
        let view = SkyLayer.defaultViewAzimuth(latitude: s.latitude)
        s.sun = SkyDirection(azimuth: view, altitude: 4)
        s.moon = SkyDirection(azimuth: view + 180, altitude: -30)
        let c = SkyPalette.colours(sunAltitude: 4, cloud: 0, mist: 0, moonlight: 0)
        s.zenith = c.zenith; s.horizon = c.horizon
        s.starVisibility = 0; s.cloudCover = 0; s.mist = 0; s.halo = 0; s.rainbow = 0
        s.diamondDust = 0   // the pillar alone (the crystals are the weather layer's, tested below)
        func ratio(pillar: Float) throws -> Double {
            var st = s; st.pillar = pillar
            let (image, sky) = try renderSky(st, viewAzimuth: view)
            let above = screenPoint(SkyDirection(azimuth: view, altitude: 10), sky: sky, latitude: st.latitude)
            let beside = screenPoint(SkyDirection(azimuth: view + 6, altitude: 10), sky: sky, latitude: st.latitude)
            return luma(rgb(image, at: above, radius: 2)) / max(1e-6, luma(rgb(image, at: beside, radius: 2)))
        }
        let on = try ratio(pillar: 1), off = try ratio(pillar: 0)
        XCTAssertGreaterThanOrEqual(on, 1.3, "pillar against beside: \(on)")
        XCTAssertEqual(off, 1, accuracy: 0.1, "no pillar: \(off)")
    }

    // MARK: - Iridescent cloud and rime frost (Sets 9 & 10)

    /// Light cloud with the sun 20° up, 30° left of the view's centre, and iridescence forced to 1 (spec §6.3). A
    /// patch 15° from the sun holding a cloud's edge takes on colour across the sky's own hue (pastel pinks and
    /// greens; a plain blue sky over white cloud has almost none, its variance is the 8-bit floor) ≥ 1.5× the same
    /// frame with iridescence 0 (the CPU reference render measured about 35×). 60° from the sun nothing changes.
    func testIridescenceTintsThinCloudNearTheSun() throws {
        var s = frozen(13)
        s.sun = SkyDirection(azimuth: 0, altitude: 20)
        s.moon = SkyDirection(azimuth: 180, altitude: -30); s.moonLit = 0
        let c = SkyPalette.colours(sunAltitude: 20, cloud: 0.35, mist: 0.15, moonlight: 0)
        s.zenith = c.zenith; s.horizon = c.horizon
        s.cloudCover = 0.35; s.mist = 0.15; s.wind = 0.2
        s.starVisibility = 0; s.halo = 0; s.rainbow = 0; s.dawnPastel = 0; s.gust = 0
        s.aurora = 0; s.fireflies = 0; s.diamondDust = 0; s.pillar = 0; s.rime = 0
        func frame(_ iridescence: Float) throws -> (image: CGImage, sky: SkyLayer) {
            var st = s; st.iridescence = iridescence
            return try renderConfigured(st) { r in r.sky.viewAzimuth = 30; r.sky.horizonY = -0.33 }
        }
        let on = try frame(1), off = try frame(0)
        XCTAssertEqual(on.sky.uniforms[SkyLayer.stillRow], SIMD4<Float>(1, 0, 0.2, 0), "iridescence, rime, the wind on screen")
        // A patch ±4° about the point at the sun's altitude `degrees` from it, toward the view's centre.
        let alt = 20.0 * Double.pi / 180
        func patch(_ degrees: Double, _ image: CGImage) -> [SIMD3<Double>] {
            let r = degrees * Double.pi / 180
            let dAz = acos(min(1, max(-1, (cos(r) - sin(alt) * sin(alt)) / (cos(alt) * cos(alt))))) * 180 / .pi
            let centre = screenPoint(SkyDirection(azimuth: dAz, altitude: 20), sky: on.sky, latitude: s.latitude)
            let side = screenPoint(SkyDirection(azimuth: dAz + 4 / cos(alt), altitude: 20), sky: on.sky, latitude: s.latitude)
            let above = screenPoint(SkyDirection(azimuth: dAz, altitude: 24), sky: on.sky, latitude: s.latitude)
            let hx = abs(side.x - centre.x), hy = abs(above.y - centre.y)
            return FramePatch.pixels(image, x: (centre.x - hx)...(centre.x + hx), y: (centre.y - hy)...(centre.y + hy))
        }
        let w = SIMD3<Double>(0.2126, 0.7152, 0.0722)
        func lum(_ p: SIMD3<Double>) -> Double { simd_dot(p, w) }
        // Each pixel's colour less its luminance, with the part along the reference patch's mean (the sky's hue) taken
        // out; the variance of what is left.
        func crossHueVariance(_ px: [SIMD3<Double>], reference: [SIMD3<Double>]) -> Double {
            func chroma(_ p: SIMD3<Double>) -> SIMD3<Double> { p - SIMD3(repeating: lum(p)) }
            let mean = reference.reduce(SIMD3<Double>(repeating: 0)) { $0 + chroma($1) } / Double(max(1, reference.count))
            let axis = simd_length(mean) > 1e-9 ? simd_normalize(mean) : SIMD3<Double>(0, 0, 1)
            let rest = px.map { p -> SIMD3<Double> in let q = chroma(p); return q - axis * simd_dot(q, axis) }
            let m = rest.reduce(SIMD3<Double>(repeating: 0), +) / Double(max(1, rest.count))
            return rest.reduce(0) { $0 + simd_length_squared($1 - m) } / Double(max(1, rest.count))
        }
        let near0 = patch(15, off.image), near1 = patch(15, on.image)
        let lumas = near0.map(lum)
        XCTAssertGreaterThan((lumas.max() ?? 0) - (lumas.min() ?? 0), 0.08, "the patch holds a cloud's edge")
        let v0 = crossHueVariance(near0, reference: near0), v1 = crossHueVariance(near1, reference: near0)
        XCTAssertGreaterThanOrEqual(v1, 1.5 * v0, "15° from the sun: \(v0) → \(v1)")
        // 60° away (iridescence is gone by 40°): the same light and the same colour.
        let far0 = patch(60, off.image), far1 = patch(60, on.image)
        func meanLuma(_ px: [SIMD3<Double>]) -> Double { px.reduce(0) { $0 + lum($1) } / Double(max(1, px.count)) }
        XCTAssertFalse(far0.isEmpty)
        XCTAssertEqual(meanLuma(far1), meanLuma(far0), accuracy: 0.05 * meanLuma(far0), "60° from the sun")
        let f0 = crossHueVariance(far0, reference: far0), f1 = crossHueVariance(far1, reference: far0)
        XCTAssertEqual(f1, f0, accuracy: max(0.05 * f0, 1e-6), "60° from the sun: colour")
    }

    func testFirefliesAndCrystalsFollowTheirWeathers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let w = try XCTUnwrap(WeatherLayer(device: device))
        let size = CGSize(width: 640, height: 360)
        var s = darkNight()
        s.rain = 0; s.snow = 0
        s.fireflies = 1
        w.update(s, quality: .high, size: size, dt: 1.0 / 30, surface: .ground(horizonY: -0.3))
        XCTAssertEqual(w.fireflyCount, WeatherLayer.fireflyCap(.high))
        XCTAssertEqual(w.crystalCount, 0, "no dust, no crystals")
        w.update(s, quality: .high, size: size, dt: 1.0 / 30, surface: .water(horizonY: -0.3))
        XCTAssertGreaterThan(w.fireflyCount, 0)
        w.update(s, quality: .high, size: size, dt: 1.0 / 30, surface: .glass)
        XCTAssertEqual(w.fireflyCount, 0, "none on glass")
        w.update(s, quality: .high, size: size, dt: 1.0 / 30, surface: .none)
        XCTAssertEqual(w.fireflyCount, 0, "none without a surface")
        s.fireflies = 0.5
        w.update(s, quality: .ultra, size: size, dt: 1.0 / 30, surface: .ground(horizonY: -0.3))
        XCTAssertEqual(w.fireflyCount, WeatherLayer.fireflyCap(.ultra) / 2)
        s.fireflies = 0
        w.update(s, quality: .high, size: size, dt: 1.0 / 30, surface: .ground(horizonY: -0.3))
        XCTAssertEqual(w.fireflyCount, 0)

        s.diamondDust = 1
        for q in QualityLevel.allCases {
            w.update(s, quality: q, size: size, dt: 1.0 / 30, surface: .glass)
            XCTAssertEqual(w.crystalCount, WeatherLayer.crystalCap(q), "\(q)")
            XCTAssertEqual(w.fireflyCount, 0)
        }
        XCTAssertLessThan(WeatherLayer.crystalCap(.lite), WeatherLayer.crystalCap(.high))
        XCTAssertLessThan(WeatherLayer.crystalCap(.high), WeatherLayer.crystalCap(.ultra))
        XCTAssertLessThan(WeatherLayer.fireflyCap(.lite), WeatherLayer.fireflyCap(.high))
        XCTAssertLessThan(WeatherLayer.fireflyCap(.high), WeatherLayer.fireflyCap(.ultra))
        XCTAssertLessThanOrEqual(WeatherLayer.fireflyCap(.lite), 60, "Smooth stays light")
        XCTAssertLessThanOrEqual(WeatherLayer.crystalCap(.lite), 150, "Smooth stays light")
        s.diamondDust = 0
        w.update(s, quality: .high, size: size, dt: 1.0 / 30, surface: .glass)
        XCTAssertEqual(w.crystalCount, 0)

        // Rime frost's freezing fog: the same crystals as a fine ice-fog drift, sparse and settling slowly (spec §6.4).
        var fog = darkNight(); fog.weather = .rime; fog.nextWeather = .rime; fog.weatherBlend = 0
        for q in QualityLevel.allCases {
            w.update(fog, quality: q, size: size, dt: 1.0 / 30, surface: .ground(horizonY: -0.3))
            XCTAssertEqual(w.crystalCount, Int((Float(WeatherLayer.crystalCap(q)) * WeatherLayer.rimeFogDensity).rounded()), "\(q)")
        }
        XCTAssertLessThanOrEqual(WeatherLayer.rimeFogDensity, 0.35, "low density")
        XCTAssertEqual(WeatherLayer.crystalMix(fog).fogShare, 1, accuracy: 1e-6)
        XCTAssertLessThan(WeatherLayer.rimeFogFall, 0.5, "slower than diamond dust")
        fog.diamondDust = 1   // dust and fog together: the cap, mostly dust
        XCTAssertEqual(WeatherLayer.crystalMix(fog).amount, 1, accuracy: 1e-6)
        XCTAssertLessThan(WeatherLayer.crystalMix(fog).fogShare, 0.3)
        XCTAssertEqual(WeatherLayer.crystalMix(darkNight()).amount, 0, "no fog, no dust: none")

        // Both draw (a frame with them is brighter than one without) and live in the shared ring buffer.
        var both = darkNight(); both.fireflies = 1; both.diamondDust = 1
        let lit = PreviewRenderer.stats(try render(both, weather: .ground(horizonY: -0.33), frames: 10)).meanLuminance
        let dark = PreviewRenderer.stats(try render(darkNight(), weather: .ground(horizonY: -0.33), frames: 10)).meanLuminance
        XCTAssertGreaterThan(lit, dark)
    }

    /// Review focus 4: the star texture arrives late (a background build). Every sky and world renders without it
    /// (the procedural stars, a placeholder bound at texture 0) and with it, and no frame waits for it.
    func testSkyRendersBeforeAndAfterTheStarTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let cache = StarTextureCache.shared
        defer { cache.withheld = false }
        let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
        XCTAssertEqual(r.sky.uniforms.count, SkyLayer.uniformCount)
        XCTAssertEqual(SkyLayer.uniformCount, 25)

        cache.withheld = true
        XCTAssertNil(r.sky.starTexture)
        XCTAssertEqual(r.sky.uniforms[8].w, 0, "the shader is told to use the procedural stars")
        let before = try render(darkNight())
        XCTAssertGreaterThan(PreviewRenderer.stats(before).variance, 0, "procedural stars before the texture")
        var lake = SkySettings(); lake.timeMode = .frozen; lake.frozenHour = 22; lake.cityID = "melbourne"
        lake.weatherMode = .pick; lake.weather = .clear
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        for id in [MoonlitLakeModel.id, GoldenHourBeachModel.id, CoastRoadModel.id, SnowboundCabinModel.id, BedroomDawnModel.id,
                   AuroraFjordModel.id, BioluminescentBayModel.id] {
            let image = try XCTUnwrap(preview.render(themeID: id, at: [0.5], sky: lake).first, id)
            XCTAssertGreaterThan(PreviewRenderer.stats(image).variance, 0, "\(id) without the stars")
        }

        cache.withheld = false
        XCTAssertTrue(r.sky.awaitStars(), "the texture arrives within seconds")
        XCTAssertNotNil(r.sky.starTexture)
        XCTAssertEqual(r.sky.uniforms[8].w, 1)
        XCTAssertEqual(r.sky.starTexture?.width, StarTexture.width)
        XCTAssertEqual(r.sky.starTexture?.height, StarTexture.height)
        XCTAssertEqual(r.sky.starTexture?.pixelFormat, MTLPixelFormat.rgba8Unorm)
        XCTAssertEqual(cache.builds, 1, "built once per process")
        let after = try render(darkNight())
        XCTAssertGreaterThan(PreviewRenderer.stats(after).variance, 0, "real stars after")
        XCTAssertGreaterThan(FramePatch.difference(before, after, x: -1...1, y: -1...1), 0, "the real stars change the sky")
        for id in [MoonlitLakeModel.id, GoldenHourBeachModel.id, CoastRoadModel.id, SnowboundCabinModel.id, BedroomDawnModel.id,
                   AuroraFjordModel.id, BioluminescentBayModel.id] {
            let image = try XCTUnwrap(preview.render(themeID: id, at: [0.5], sky: lake).first, id)
            XCTAssertGreaterThan(PreviewRenderer.stats(image).variance, 0, "\(id) with the stars")
        }
        _ = SkyOnlyRenderer(device: device)
        XCTAssertEqual(cache.builds, 1, "a new sky shares the texture")
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

    /// Steps the lake at 60 fps with each frame's sky edited (no notes) and captures the frame at `seconds`.
    private func renderLake(at seconds: Double, sky: SkySettings, quality: QualityLevel, width: Int, height: Int,
                            skyEdit: (inout SkyState) -> Void) throws -> (image: CGImage, renderer: MoonlitLakeRenderer) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(MoonlitLakeRenderer(device: device))
        let d = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky)
        d.mood = .serene
        let size = CGSize(width: width, height: height)
        for i in 1...Int(seconds * 60) {
            let t = Double(i) / 60
            elapsed = t
            guard var f = d.step(dt: 1.0 / 60, t: t, quality: quality) as? LakeFrame else { continue }
            skyEdit(&f.sky)
            r.update(f, params: d.parameters, quality: quality, gentle: false, dt: 1.0 / 60, size: size)
        }
        return (try XCTUnwrap(preview.capture(r)), r)
    }

    /// Rime frost at midday (clear, the sun high and out of view): the far shore's edge — silhouette pixels (darker
    /// than half the sky) within 3 px of brighter pixels beside or above them — is ≥ 15% brighter with the world fully
    /// rimed (the CPU reference render measured about 2× at every view azimuth). Smooth (no depth of field) at the
    /// previews' size, so the fringe spans a few pixels.
    func testRimeWhitensTheLakePines() throws {
        let w = 1280, h = 720
        let noon = GoldenHourBeachRendererTests.midday
        let bare = try renderLake(at: 1, sky: noon, quality: .lite, width: w, height: h) { $0.rime = 0 }
        let rimed = try renderLake(at: 1, sky: noon, quality: .lite, width: w, height: h) { $0.rime = 1 }
        let l0 = FramePatch.luminance(bare.image), l1 = FramePatch.luminance(rimed.image)
        // The band from the horizon up past the pines, clear of the reeds at the frame's edges.
        let horizon = Double(bare.renderer.horizonY)
        var region: [Int] = []
        for row in 0..<h {
            let y = 1 - 2 * (Double(row) + 0.5) / Double(h)
            guard y >= horizon, y <= horizon + 0.25 else { continue }
            for col in 0..<w where abs(2 * (Double(col) + 0.5) / Double(w) - 1) <= 0.6 { region.append(row * w + col) }
        }
        let sorted = region.map { l0[$0] }.sorted()
        let sky = sorted[Int(Double(sorted.count - 1) * 0.9)]
        func bright(_ i: Int) -> Bool { l0[i] >= 0.5 * sky }
        var sum0 = 0.0, sum1 = 0.0, n = 0
        for i in region where !bright(i) {
            let row = i / w, col = i % w
            var edge = false
            for k in 1...3 where !edge {
                edge = (col - k >= 0 && bright(i - k)) || (col + k < w && bright(i + k)) || (row - k >= 0 && bright(i - k * w))
            }
            if edge { sum0 += l0[i]; sum1 += l1[i]; n += 1 }
        }
        XCTAssertGreaterThan(n, 500, "the far shore's edge is in view")
        let before = sum0 / Double(max(1, n)), after = sum1 / Double(max(1, n))
        XCTAssertGreaterThanOrEqual(after, 1.15 * before, "the pines' edge: \(before) → \(after)")
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
                             ("sky", SkyShaders.source), ("bay", BioluminescentBayShaders.source)] {
            let source = name == "ocean" || name == "sky" ? full : String(full.dropFirst(shared))
            let hits = pattern.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
            XCTAssertEqual(hits, 0, name)
        }
        // The worlds built on the sky alone (their reflections call skyRadiance, with the aurora, stars and pillars).
        for (name, full) in [("lake", MoonlitLakeShaders.source), ("cabin", SnowboundCabinShaders.source),
                             ("bedroom", BedroomDawnShaders.source), ("fjord", AuroraFjordShaders.source)] {
            let source = String(full.dropFirst(SkyShaders.common.count))
            let hits = pattern.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
            XCTAssertEqual(hits, 0, name)
        }
        // The Underwater Kit, its probe and the porthole: no pow() at all (Beer–Lambert is exp, squares are written out).
        XCTAssertFalse(UnderwaterShaders.common.contains("pow("), "the Underwater Kit")
        XCTAssertFalse(String(UnderwaterProbe.source.dropFirst(SkyShaders.common.count)).contains("pow("), "the Underwater Kit's probe")
        for fn in ["float3 portView(", "fragment float4 port_glass_fragment(", "fragment ColorDepth port_frame_fragment("] {
            let start = try XCTUnwrap(WindowKitShaders.source.range(of: fn), fn)
            let tail = WindowKitShaders.source[start.lowerBound...]
            let end = tail.range(of: "\n}\n")?.upperBound ?? tail.endIndex
            XCTAssertFalse(tail[..<end].contains("pow("), fn)
        }
        // Any pow() in the new sky code takes a base that cannot be negative: none at all in the aurora, the real stars,
        // the pillars, iridescent cloud and the rime helpers every world calls.
        for fn in ["float3 realStars(", "float3 auroraLight(", "float lightPillar(", "float fbm3c(", "float3 iridescentCloud(",
                   "bool rimeNear(", "float rimeFringe(", "void rimeKeepDeepest(", "float rimeFeather(", "float rimeEdge(",
                   "float3 rimeColor(", "float3 rimed("] {
            let start = try XCTUnwrap(SkyShaders.common.range(of: fn), fn)
            let tail = SkyShaders.common[start.lowerBound...]
            let end = tail.range(of: "\n}\n")?.upperBound ?? tail.endIndex   // the function's closing brace (column 0)
            XCTAssertFalse(tail[..<end].contains("pow("), fn)
        }
        // And none in the worlds' own rime code (the silhouettes that call it).
        for (source, fn) in [(MoonlitLakeShaders.source, "float3 ridgeColor("), (MoonlitLakeShaders.source, "float reeds("),
                             (SnowboundCabinShaders.source, "float pine("), (GoldenHourBeachShaders.source, "float palmTree("),
                             (GoldenHourBeachShaders.source, "float shoreSilhouettes("), (CoastRoadShaders.source, "float lampPostRime(")] {
            let start = try XCTUnwrap(source.range(of: fn), fn)
            let tail = source[start.lowerBound...]
            let end = tail.range(of: "\n}\n")?.upperBound ?? tail.endIndex
            XCTAssertFalse(tail[..<end].contains("pow("), fn)
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
        // A morning in rime frost's freezing fog with the world fully rimed (the sky takes 10–20 minutes to get there).
        let rime = try XCTUnwrap(preview.render(themeID: MoonlitLakeModel.id, at: [5], quality: .high,
                                                sky: sky(hour: 8.5, phase: 0.55, weather: .rime), mood: .serene,
                                                skyEdit: { $0.rime = 1 }).first)
        try PreviewRenderer.writePNG(rime, to: url.appendingPathComponent("lake-rime.png"))
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

        // Night-sky additions: the aurora (south from Melbourne, overhead in the north), the real stars and their lines,
        // diamond dust's pillars, a humid night's fireflies (forced states, so each shows its feature).
        var night = state(hour: 23.5, phase: 0.05, weather: .clear)
        night.sun = SkyDirection(azimuth: 0, altitude: -40); night.moon = SkyDirection(azimuth: 0, altitude: -30); night.moonLit = 0
        let nightColours = SkyPalette.colours(sunAltitude: -40, cloud: 0, mist: 0, moonlight: 0)
        night.zenith = nightColours.zenith; night.horizon = nightColours.horizon
        night.starVisibility = 1; night.cloudCover = 0; night.mist = 0; night.constellationLines = 0.35
        /// A star's east-north-up direction with the shader's basis.
        func enu(ra: Float, dec: Float, _ s: SkyState) -> SIMD3<Float> {
            let a = Double(ra) * .pi / 180, d = Double(dec) * .pi / 180
            let v = SIMD3<Float>(Float(cos(d) * cos(a)), Float(cos(d) * sin(a)), Float(sin(d)))
            let b = SkyLayer.equatorialBasis(siderealDegrees: s.siderealDegrees, latitude: s.latitude)
            return SIMD3(simd_dot(v, b.east), simd_dot(v, b.north), simd_dot(v, b.up))
        }
        /// (view azimuth, horizon y) that centre the camera on a direction.
        func aim(_ e: SIMD3<Float>, fov: Double = 60) -> (Double, Float) {
            let alt = asin(Double(min(1, max(-1, e.z))))
            return (atan2(Double(e.x), Double(e.y)) * 180 / .pi, Float(-tan(alt) / tan(fov * .pi / 360)))
        }
        var australis = night
        australis.aurora = 0.85; australis.auroraAltitude = 14; australis.auroraStorm = 0.55; australis.hemisphere = -1
        var borealis = night
        borealis.latitude = 69.6; borealis.hemisphere = 1
        borealis.aurora = 1; borealis.auroraAltitude = 78; borealis.auroraStorm = 0.9
        let acrux = try XCTUnwrap(StarCatalogue.star(hip: 60718)), gacrux = try XCTUnwrap(StarCatalogue.star(hip: 61084))
        var crux = night
        crux.siderealDegrees = Double(acrux.ra + gacrux.ra) / 2 + 30
        let cruxDir = simd_normalize(enu(ra: acrux.ra, dec: acrux.dec, crux) + enu(ra: gacrux.ra, dec: gacrux.dec, crux))
        let betelgeuse = try XCTUnwrap(StarCatalogue.star(hip: 27989))
        var orion = night
        orion.siderealDegrees = Double(betelgeuse.ra) + 10; orion.constellationLines = 1
        let orionDir = enu(ra: betelgeuse.ra - 4, dec: betelgeuse.dec - 8, orion)
        var pillars = state(hour: 13, phase: 0.5, weather: .diamondDust)
        pillars.sun = SkyDirection(azimuth: ahead, altitude: 4)
        let pillarColours = SkyPalette.colours(sunAltitude: 4, cloud: 0.05, mist: 0.2, moonlight: 0)
        pillars.zenith = pillarColours.zenith; pillars.horizon = pillarColours.horizon
        pillars.halo = 1; pillars.diamondDust = 1; pillars.pillar = 1; pillars.starVisibility = 0
        var humid = state(hour: 23.5, phase: 0.3, weather: .humid)
        humid.fireflies = 1
        let ground = WeatherSurface.ground(horizonY: -0.33)
        let nightCases: [(String, SkyState, (Double, Float)?, WeatherSurface)] = [
            ("sky-aurora-australis", australis, (180, -0.33), .none),
            ("sky-aurora-borealis-overhead", borealis, (5, -1.6), .none),
            ("sky-real-stars-crux", crux, aim(cruxDir), .none),
            ("sky-constellation-lines", orion, aim(orionDir), .none),
            ("sky-diamond-dust-pillars", pillars, (ahead, -0.33), ground),
            ("sky-humid-fireflies", humid, nil, ground),
        ]
        for (name, st, view, surface) in nightCases {
            let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
            XCTAssertTrue(r.sky.awaitStars())
            if let view { r.sky.viewAzimuth = view.0; r.sky.horizonY = view.1 }   // a ground surface sets its own horizon
            for i in 0..<45 {
                r.update(st, quality: .high, size: CGSize(width: 1280, height: 720), dt: 1.0 / 30, time: Float(i) / 30, surface: surface)
            }
            let image = try XCTUnwrap(preview.capture(r))
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }

        // Iridescent cloud: a light-cloud spell's pastel bands with the sun 14° up ahead (low enough for a cap over the
        // cells), iridescence forced to 1.
        var iridescent = state(hour: 13, phase: 0.5, weather: .lightCloud)
        iridescent.sun = SkyDirection(azimuth: ahead, altitude: 14)
        let iriColours = SkyPalette.colours(sunAltitude: 14, cloud: iridescent.cloudCover, mist: iridescent.mist, moonlight: 0)
        iridescent.zenith = iriColours.zenith; iridescent.horizon = iriColours.horizon
        iridescent.iridescence = 1; iridescent.starVisibility = 0
        let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
        r.sky.viewAzimuth = ahead + 12; r.sky.horizonY = -0.45
        for i in 0..<10 { r.update(iridescent, quality: .high, size: CGSize(width: 1280, height: 720), dt: 1.0 / 30, time: Float(i) / 30, surface: .none) }
        try PreviewRenderer.writePNG(try XCTUnwrap(preview.capture(r)), to: url.appendingPathComponent("sky-iridescent-cloud.png"))
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
        // Rime frost: the pines feathered white on their windward side (the world held fully rimed).
        let rime = try XCTUnwrap(preview.render(themeID: SnowboundCabinModel.id, at: [5], state: follow, quality: .high,
                                                sky: sky(9, .rime, 0.5), mood: .hushedWarm, skyEdit: { $0.rime = 1 }).first)
        try PreviewRenderer.writePNG(rime, to: url.appendingPathComponent("cabin-rime.png"))
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

/// Aurora Fjord (Set 7's world) with Curtain Lights.
@MainActor
final class AuroraFjordRendererTests: XCTestCase {
    func testFjordShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: AuroraFjordShaders.source, options: nil)
        for name in ["fjord_vertex", "fjord_scene_fragment", "fjord_village_vertex", "fjord_village_fragment", "fjord_floe_vertex",
                     "fjord_floe_fragment", "fjord_rail_vertex", "fjord_rail_fragment", "fjord_keys_vertex", "fjord_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
        let own = String(AuroraFjordShaders.source.dropFirst(SkyShaders.common.count))
        XCTAssertFalse(own.contains("pow("), "squares and powers are written out")
    }

    /// Melbourne, frozen: a dark moon (a thin crescent set with the sun) unless asked.
    nonisolated static func sky(hour: Double, weather: WeatherKind = .clear, phase: Double = 0.1) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = weather
        return s
    }

    struct FjordShot { var image: CGImage; var renderer: AuroraFjordRenderer; var frame: FjordFrame }

    /// Steps the fjord at 60 fps in its own mood (notes go down at `noteTime` and stay held) and captures frames at the
    /// given times (seconds, ascending). The world's defaults hold Deep night with the aurora Always.
    private func fjordShots(notes: [UInt8] = [], velocity: Float = 1, noteTime: Double = 0.5, at times: [Double],
                            state: ThemeState = ThemeState(), sky: SkySettings = AuroraFjordRendererTests.sky(hour: 22),
                            quality: QualityLevel = .high, gentle: Bool = false, width: Int = 640, height: Int = 360,
                            skyEdit: ((inout SkyState) -> Void)? = nil) throws -> [FjordShot] {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(AuroraFjordRenderer(device: device))
        let d = SceneDirector(themeID: AuroraFjordModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky)
        d.mood = .electricAwe
        let size = CGSize(width: width, height: height)
        let noteStep = max(1, Int((noteTime * 60).rounded()))
        var shots: [FjordShot] = []
        var pending = times
        var i = 0
        while let next = pending.first, i < 60 * 120 {
            i += 1
            let t = Double(i) / 60
            elapsed = t
            if i == noteStep, !notes.isEmpty { d.handle(notes.map { .noteOn(note: $0, velocity: velocity) }, at: t) }
            var f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: quality) as? FjordFrame)
            skyEdit?(&f.sky)
            r.update(f, params: d.parameters, quality: quality, gentle: gentle, dt: 1.0 / 60, size: size)
            if t >= next - 1e-9 {
                shots.append(FjordShot(image: try XCTUnwrap(preview.capture(r)), renderer: r, frame: f))
                pending.removeFirst()
            }
        }
        XCTAssertEqual(shots.count, times.count)
        return shots
    }

    private func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
    private func luma(_ image: CGImage, _ box: (x: ClosedRange<Double>, y: ClosedRange<Double>)) -> Double {
        luma(FramePatch.meanRGB(image, x: box.x, y: box.y))
    }

    /// The NDC y of an altitude (degrees) straight ahead, through the fjord's camera at this aspect.
    private func ndcY(altitude: Double, renderer r: AuroraFjordRenderer, aspect: Float = 640.0 / 360) -> Double {
        let tanV = tan(AuroraFjordRenderer.verticalFOV(aspect: aspect) * .pi / 360)
        let pitch = atan(-Double(r.horizonY) * tanV)
        return tan(altitude * .pi / 180 - pitch) / tanV
    }

    func testFjordPreviewIsStructured() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        for q in [QualityLevel.lite, .high] {
            for (name, state, hour) in [("night", ThemeState(), 22.0), ("dawn", follow, 7.6), ("noon", follow, 13.0)] {
                let image = try XCTUnwrap(preview.render(themeID: AuroraFjordModel.id, at: [1], state: state, quality: q,
                                                         sky: Self.sky(hour: hour), mood: .electricAwe).first)
                let s = PreviewRenderer.stats(image)
                XCTAssertGreaterThan(s.meanLuminance, 0.02, "\(q) \(name)")
                XCTAssertGreaterThan(s.variance, 0.002, "\(q) \(name)")
            }
        }
    }

    /// A held MIDI 60 from 1 s: a second later the curtain's foot where the ripple's right-hand front has travelled
    /// along the band is ≥ 1.25× as bright as before the note (the ripple dips the curtain's foot and brightens it); a
    /// patch far along the band stays within 10% (the held note's glow eases in). Stars and the moon are off, so the
    /// patches measure the curtain alone.
    func testNotesRippleTheCurtain() throws {
        let dark: (inout SkyState) -> Void = { s in
            s.starVisibility = 0; s.moon = SkyDirection(azimuth: 0, altitude: -30); s.moonLit = 0
        }
        let shots = try fjordShots(notes: [60], noteTime: 1, at: [59.0 / 60, 2], skyEdit: dark)
        let before = shots[0], after = shots[1]
        XCTAssertGreaterThan(after.frame.sky.aurora, 0.5, "Always, at deep night")
        XCTAssertEqual(after.renderer.rippleCount, 1)
        let ripple = try XCTUnwrap(after.frame.ripples.first)
        XCTAssertEqual(Double(ripple.age), 1, accuracy: 0.02)
        let sent = after.renderer.shaderRipples[0]
        XCTAssertEqual(sent, AuroraFjordRenderer.shaderRipple(ripple, sparkle: 1))
        let front = AuroraFjordRenderer.fronts(sent).right
        func box(_ p0: Float, _ p1: Float, _ a0: Float, _ a1: Float) throws -> (x: ClosedRange<Double>, y: ClosedRange<Double>) {
            var lo = SIMD2<Float>(repeating: 9), hi = SIMD2<Float>(repeating: -9)
            for p in [p0, (p0 + p1) / 2, p1] {
                for a in [a0, (a0 + a1) / 2, a1] {
                    let q = try XCTUnwrap(after.renderer.bandPoint(position: p, above: a))
                    lo = simd_min(lo, q); hi = simd_max(hi, q)
                }
            }
            return (Double(lo.x)...Double(hi.x), Double(lo.y)...Double(hi.y))
        }
        // The curtain's foot (4.5° under its base to 1° over it), 1.5° either side of the front.
        let near = try box(front - 1.5 / 180, front + 1.5 / 180, -4.5, 1)
        // 24–30° along the band to the left, 10–16° up the curtain: clear of both fronts and over the left wall.
        let far = try box(0.5 - 30.0 / 180, 0.5 - 24.0 / 180, 10, 16)
        let nearBefore = luma(before.image, near), nearAfter = luma(after.image, near)
        XCTAssertGreaterThanOrEqual(nearAfter, 1.25 * nearBefore, "at the ripple: \(nearBefore) → \(nearAfter)")
        let farBefore = luma(before.image, far), farAfter = luma(after.image, far)
        XCTAssertEqual(farAfter, farBefore, accuracy: 0.1 * farBefore, "far along the band: \(farBefore) → \(farAfter)")
    }

    func testFjordHonoursGentleVisuals() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let d = SceneDirector(themeID: AuroraFjordModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: Self.sky(hour: 22))
        d.mood = .electricAwe
        let plain = try XCTUnwrap(AuroraFjordRenderer(device: device)), gentle = try XCTUnwrap(AuroraFjordRenderer(device: device))
        let size = CGSize(width: 640, height: 360)
        var glow: (plain: Float, gentle: Float) = (0, 0), ripple: (plain: Float, gentle: Float) = (0, 0)
        for i in 1...150 {
            let t = Double(i) / 60
            elapsed = t
            if i == 10 { d.handle([60, 64, 67].map { .noteOn(note: $0, velocity: 0.9) }, at: t) }
            let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: .high) as? FjordFrame)
            plain.update(f, params: d.parameters, quality: .high, gentle: false, dt: 1.0 / 60, size: size)
            gentle.update(f, params: d.parameters, quality: .high, gentle: true, dt: 1.0 / 60, size: size)
            glow = (max(glow.plain, plain.glowOut), max(glow.gentle, gentle.glowOut))
            ripple = (max(ripple.plain, plain.shaderRipples.map(\.z).max() ?? 0), max(ripple.gentle, gentle.shaderRipples.map(\.z).max() ?? 0))
        }
        XCTAssertGreaterThan(glow.plain, 0.2, "a held chord swells the curtain")
        XCTAssertLessThanOrEqual(glow.gentle, glow.plain * 0.55, "gentle visuals halve the swell")
        XCTAssertGreaterThan(ripple.plain, 0.5)
        XCTAssertLessThanOrEqual(ripple.gentle, ripple.plain * 0.55, "and the ripples")
    }

    /// Diamond dust at night: the column over a village light (2.5–6° above it) is ≥ 1.2× as bright as on a clear night.
    /// The crystals are left out (they're the weather layer's), so the column measures the pillar alone.
    func testVillageLightsPillarInDiamondDust() throws {
        let clear = try XCTUnwrap(fjordShots(at: [1.5]).last)
        let dust = try XCTUnwrap(fjordShots(at: [1.5], sky: Self.sky(hour: 22, weather: .diamondDust)) { $0.diamondDust = 0 }.last)
        XCTAssertEqual(clear.frame.sky.pillar, 0)
        XCTAssertGreaterThan(dust.frame.sky.pillar, 0.9)
        XCTAssertTrue(clear.frame.villageLit && dust.frame.villageLit)
        XCTAssertGreaterThanOrEqual(clear.renderer.villageLightCount, 6)
        XCTAssertLessThanOrEqual(clear.renderer.villageLightCount, AuroraFjordRenderer.maxVillageLights)
        XCTAssertEqual(dust.renderer.villagePoints, clear.renderer.villagePoints, "the village stays put")
        // The leftmost light: the column above it lies on the wall's face, below the skyline.
        let light = try XCTUnwrap(clear.renderer.villagePoints.min { $0.x < $1.x })
        let tanV = Float(tan(AuroraFjordRenderer.verticalFOV(aspect: 640.0 / 360) * .pi / 360))
        func above(_ degrees: Float) -> Double { Double(tan(atan(light.y * tanV) + degrees * .pi / 180) / tanV) }
        let column = (x: Double(light.x - 0.006)...Double(light.x + 0.006), y: above(2.5)...above(6))
        let a = luma(clear.image, column), b = luma(dust.image, column)
        XCTAssertGreaterThanOrEqual(b, 1.2 * a, "clear \(a), diamond dust \(b)")
    }

    /// The water below the band mirrors the aurora: ≥ 1.3× as bright with the aurora Always (at deep night) as Never.
    func testFjordReflectsTheAurora() throws {
        let always = try XCTUnwrap(fjordShots(at: [1.5], state: ThemeState(values: ["aurora.mode": .choice(AuroraMode.always.rawValue)])).last)
        let never = try XCTUnwrap(fjordShots(at: [1.5], state: ThemeState(values: ["aurora.mode": .choice(AuroraMode.never.rawValue)])).last)
        XCTAssertGreaterThan(always.frame.sky.aurora, 0.5)
        XCTAssertEqual(never.frame.sky.aurora, 0)
        // A flat mirror shows the sky as far below the horizon as it stands above it: the curtain's lowest 1–7°.
        let base = Double(AuroraFjordRenderer.framedAltitude(always.frame.sky.auroraAltitude))
        let y = ndcY(altitude: -(base + 7), renderer: always.renderer)...ndcY(altitude: -(base + 1), renderer: always.renderer)
        XCTAssertGreaterThan(y.lowerBound, -0.76, "above the keys")
        let water = (x: -0.12...0.12, y: y)
        let a = luma(always.image, water), b = luma(never.image, water)
        XCTAssertGreaterThanOrEqual(a, 1.3 * b, "aurora \(a), none \(b)")
    }

    func testFjordFramesAnyAspect() throws {
        for (w, h) in [(864, 360), (360, 360)] {
            let shot = try XCTUnwrap(fjordShots(notes: [60, 64, 67], at: [1.5], width: w, height: h).last)
            let r = shot.renderer
            XCTAssertGreaterThan(r.horizonY, -1, "\(w)×\(h)"); XCTAssertLessThan(r.horizonY, 1, "\(w)×\(h)")
            XCTAssertEqual(r.keyRects.count, 88)
            for k in r.keyRects {
                XCTAssertGreaterThanOrEqual(k.x, -1); XCTAssertLessThanOrEqual(k.z, 1)
                XCTAssertGreaterThanOrEqual(k.y, -1); XCTAssertLessThanOrEqual(k.w, 1)
                XCTAssertLessThan(k.w, r.horizonY, "the keys sit below the horizon")
            }
            XCTAssertGreaterThanOrEqual(r.villageLightCount, 6, "\(w)×\(h)")
            for p in r.villagePoints { XCTAssertTrue((-1...1).contains(p.x) && (-1...1).contains(p.y), "\(w)×\(h) village \(p)") }
            XCTAssertEqual(r.jettyPosts.count, 2, "\(w)×\(h)")
            let keyTop = r.keyRects.map(\.w).max() ?? -1
            for p in r.jettyPosts {
                XCTAssertTrue((-1...1).contains(p.x) && p.y > keyTop && p.y < r.horizonY, "\(w)×\(h) jetty \(p)")
            }
            let s = PreviewRenderer.stats(shot.image)
            XCTAssertGreaterThan(s.meanLuminance, 0.02, "\(w)×\(h)")
            XCTAssertGreaterThan(s.variance, 0.001, "\(w)×\(h)")
        }
    }

    /// 2,000 notes in a second: never more than 8 ripples on the curtain, and 60 frames update and render in under 4 s.
    func testFjordBurstStaysInBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(AuroraFjordRenderer(device: device))
        let d = SceneDirector(themeID: AuroraFjordModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        d.sky.reset(settings: Self.sky(hour: 22))
        for q in [QualityLevel.lite, .high] {
            let start = Date()
            for i in 0..<60 {
                let t = Double(i) / 60
                d.handle((0..<34).map { k in .noteOn(note: UInt8(21 + (i * 34 + k) % 88), velocity: 0.8) }, at: t)
                let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: q) as? FjordFrame)
                r.update(f, params: d.parameters, quality: q, gentle: false, dt: 1.0 / 60, size: CGSize(width: 640, height: 360))
                XCTAssertLessThanOrEqual(f.ripples.count, CurtainLights.cap)
                XCTAssertLessThanOrEqual(r.rippleCount, SkyLayer.rippleCount)
                XCTAssertNotNil(preview.capture(r))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 4, "\(q)")
        }
        XCTAssertGreaterThan(r.rippleCount, 0)
        XCTAssertEqual(r.floeCount, AuroraFjordModel.floeCount(0.6))
    }
}

extension WorldPreviewTests {
    func testWriteFjordPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let night = ThemeState()
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        let warp = ThemeState(values: ["visual": .choice("Galaxy Warp")])
        let sky = AuroraFjordRendererTests.sky
        let cases: [(String, SkySettings, ThemeState, QualityLevel, Double)] = [
            ("fjord-night-aurora", sky(22, .clear, 0.1), night, .high, 5),
            ("fjord-dawn", sky(7.6, .clear, 0.1), follow, .high, 5),
            ("fjord-noon", sky(13, .clear, 0.1), follow, .high, 5),
            ("fjord-diamond-dust", sky(22, .diamondDust, 0.1), night, .high, 5),
            ("fjord-blizzard", sky(13, .blizzard, 0.1), follow, .high, 5),
            ("fjord-smooth", sky(22, .clear, 0.1), night, .lite, 5),
            ("fjord-ripples-t2", sky(22, .clear, 0.1), night, .high, 2),
            ("fjord-warp-t7", sky(22, .clear, 0.1), warp, .high, 7),
        ]
        for (name, s, state, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: AuroraFjordModel.id, at: [t], state: state, quality: q, sky: s,
                                                     mood: .electricAwe).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
    }
}

/// Bioluminescent Bay (Set 8's world) with Glow Wake.
@MainActor
final class BioluminescentBayRendererTests: XCTestCase {
    func testBayShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: BioluminescentBayShaders.source, options: nil)
        for name in ["bay_vertex", "bay_fragment", "bay_keys_vertex", "bay_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
        let own = String(BioluminescentBayShaders.source.dropFirst(SkyShaders.common.count + OceanShaders.common.count))
        XCTAssertFalse(own.contains("pow("), "squares and powers are written out")
        // The Swift uniform arrays match the MSL structs byte for byte (the pipeline's own reflection says so).
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "bay_vertex")
        d.fragmentFunction = lib.makeFunction(name: "bay_fragment")
        d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
        var reflection: MTLAutoreleasedRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
        let buffers = (reflection?.fragmentBindings ?? []).compactMap { $0 as? MTLBufferBinding }
        func size(_ index: Int) -> Int? { buffers.first { $0.index == index }?.bufferDataSize }
        let row = MemoryLayout<SIMD4<Float>>.stride
        XCTAssertEqual(size(0), SkyLayer.uniformCount * row, "SkyU")
        XCTAssertEqual(size(1), BioluminescentBayRenderer.uniformCount * row, "BayU")
        XCTAssertEqual(size(2), 7 * row, "OceanU")
        XCTAssertEqual(BioluminescentBayRenderer.wakeBase, BioluminescentBayRenderer.patchBase + GlowWake.cap)
        XCTAssertEqual(BioluminescentBayRenderer.dartBase, BioluminescentBayRenderer.wakeBBase + GlowWake.wakeCap)
        XCTAssertEqual(BioluminescentBayRenderer.uniformCount, BioluminescentBayRenderer.dartBBase + GlowWake.dartCap)
        let r = try XCTUnwrap(BioluminescentBayRenderer(device: device))
        XCTAssertEqual(r.uniforms.count, BioluminescentBayRenderer.uniformCount)
        XCTAssertEqual(r.oceanUniforms.count, 7)
    }

    /// Frozen Melbourne skies (the world holds Deep night unless a test follows the sky); a thin moon by default.
    nonisolated static func sky(hour: Double, weather: WeatherKind = .clear, phase: Double = 0.1) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = weather
        return s
    }

    struct BayShot { var image: CGImage; var renderer: BioluminescentBayRenderer; var frame: BayFrame }

    /// Steps the bay at 60 fps (notes go down at 0.5 s and stay held) and renders the frame at `seconds`.
    private func renderBay(notes: [UInt8], velocity: Float = 1, at seconds: Double, state: ThemeState = ThemeState(),
                           sky: SkySettings = BioluminescentBayRendererTests.sky(hour: 22), quality: QualityLevel = .high,
                           gentle: Bool = false, width: Int = 640, height: Int = 360,
                           skyEdit: ((inout SkyState) -> Void)? = nil,
                           each: ((BioluminescentBayRenderer, BayFrame) -> Void)? = nil) throws -> BayShot {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(BioluminescentBayRenderer(device: device))
        let d = SceneDirector(themeID: BioluminescentBayModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky)
        d.mood = .secretGlow
        var frame: BayFrame?
        let size = CGSize(width: width, height: height)
        for i in 1...Int(seconds * 60) {
            let t = Double(i) / 60
            elapsed = t
            if i == 30, !notes.isEmpty { d.handle(notes.map { .noteOn(note: $0, velocity: velocity) }, at: t) }
            frame = d.step(dt: 1.0 / 60, t: t, quality: quality) as? BayFrame
            if let edit = skyEdit, frame != nil { edit(&frame!.sky) }
            if let frame {
                r.update(frame, params: d.parameters, quality: quality, gentle: gentle, dt: 1.0 / 60, size: size)
                each?(r, frame)
            }
        }
        let f = try XCTUnwrap(frame)
        return BayShot(image: try XCTUnwrap(preview.capture(r)), renderer: r, frame: f)
    }

    private func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// The median luminance inside an NDC rectangle (a reflected star in it can't move it).
    private func medianLuma(_ image: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>) -> Double {
        let l = FramePatch.pixels(image, x: x, y: y).map(luma).sorted()
        return l.isEmpty ? 0 : l[l.count / 2]
    }

    private struct LightCase { let name: String; let state: ThemeState; let sky: SkySettings; let mean: Double; let variance: Double }

    func testBayPreviewIsStructured() throws {
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        let cases = [
            LightCase(name: "night", state: ThemeState(), sky: Self.sky(hour: 22), mean: 0.012, variance: 0.0008),
            LightCase(name: "dawn", state: follow, sky: Self.sky(hour: 7.1, phase: 0.3), mean: 0.05, variance: 0.002),
            LightCase(name: "noon", state: follow, sky: Self.sky(hour: 13, phase: 0.5), mean: 0.2, variance: 0.004),
        ]
        for q in [QualityLevel.lite, .high] {
            for c in cases {
                let shot = try renderBay(notes: [60, 64, 67], at: 1.5, state: c.state, sky: c.sky, quality: q)
                let s = PreviewRenderer.stats(shot.image)
                XCTAssertGreaterThan(s.meanLuminance, c.mean, "\(q) \(c.name)")
                XCTAssertGreaterThan(s.variance, c.variance, "\(q) \(c.name)")
                XCTAssertEqual(shot.renderer.patchCount, 3, "\(q) \(c.name): the notes land in any light")
                if c.name == "night" {
                    XCTAssertGreaterThan(shot.renderer.glowOut, 0.5, "\(q): the plankton glows in the dark")
                    XCTAssertGreaterThan(shot.renderer.lanternOut, 0.4, "\(q): the lantern is lit")
                }
                if c.name == "noon" {
                    XCTAssertEqual(shot.renderer.glowOut, 0, "\(q): no glow by day")
                    XCTAssertEqual(shot.renderer.lanternOut, 0, "\(q): the lantern is out by day")
                    XCTAssertEqual(shot.renderer.lighthouseOut, 0, "\(q): nor the lighthouse")
                }
            }
        }
    }

    /// A held note at night lights its patch of water: the patch is far brighter than the water beside it.
    func testNotesLightTheWater() throws {
        let quiet = ThemeState(values: ["lantern": .number(0), "lighthouse": .number(0)])
        let shot = try renderBay(notes: [60], at: 1.5, state: quiet)
        let patch = try XCTUnwrap(shot.frame.patches.first)
        XCTAssertGreaterThan(patch.brightness, 0.5, "lit in the dark")
        XCTAssertEqual(shot.renderer.patchCount, 1)
        let box = try XCTUnwrap(shot.renderer.screenBox(of: patch))
        let cx = Double(box.centre.x), cy = Double(box.centre.y), hx = Double(box.half.x), hy = Double(box.half.y)
        XCTAssertLessThan(cy, Double(shot.renderer.horizonY), "on the water")
        XCTAssertGreaterThan(cy, Double(shot.renderer.waterlineY), "beyond the waterline")
        let y = (cy - 0.6 * hy)...(cy + 0.6 * hy)
        let inside = luma(FramePatch.meanRGB(shot.image, x: (cx - 0.4 * hx)...(cx + 0.4 * hx), y: y))
        let beside = max(medianLuma(shot.image, x: (cx - 3.4 * hx)...(cx - 2.6 * hx), y: y),
                         medianLuma(shot.image, x: (cx + 2.6 * hx)...(cx + 3.4 * hx), y: y))
        XCTAssertGreaterThanOrEqual(inside, 1.4 * beside, "patch \(inside), beside \(beside)")
    }

    /// The still bay mirrors the real stars: with them forced on, the water under the sky holds far brighter points than
    /// with them off (night, clear, no moon; the glow, lantern, lighthouse and keys off).
    func testBayMirrorsTheRealStars() throws {
        let still = ThemeState(values: ["glow": .number(0), "lantern": .number(0), "lighthouse": .number(0), "keys.show": .bool(false)])
        func water(_ visibility: Float) throws -> (bright: Double, mean: Double) {
            let shot = try renderBay(notes: [], at: 1, state: still, sky: Self.sky(hour: 22, phase: 0),
                                     skyEdit: { $0.starVisibility = visibility })
            XCTAssertNotNil(StarTextureCache.shared.texture, "the real stars are bound")
            let r = shot.renderer
            let x = -0.7...0.7, y = Double(r.waterlineY + 0.05)...Double(r.horizonY - 0.03)
            return (bright: FramePatch.brightest(shot.image, x: x, y: y, share: 0.01),
                    mean: luma(FramePatch.meanRGB(shot.image, x: x, y: y)))
        }
        let on = try water(1), off = try water(0)
        XCTAssertGreaterThanOrEqual(on.bright, 1.25 * off.bright, "reflected stars: \(off.bright) → \(on.bright)")
        XCTAssertGreaterThan(on.mean, off.mean, "the mirror carries the starlight")
    }

    func testBayHonoursGentleVisuals() throws {
        var plain: (glow: Float, flash: Float) = (glow: 0, flash: 0), gentle: (glow: Float, flash: Float) = (glow: 0, flash: 0)
        _ = try renderBay(notes: [60, 64, 67], at: 1, each: { r, _ in
            plain = (glow: max(plain.glow, r.glowOut), flash: max(plain.flash, r.lighthouseOut))
        })
        _ = try renderBay(notes: [60, 64, 67], at: 1, gentle: true, each: { r, _ in
            gentle = (glow: max(gentle.glow, r.glowOut), flash: max(gentle.flash, r.lighthouseOut))
        })
        XCTAssertGreaterThan(plain.glow, 0.3, "the plankton glows at night")
        XCTAssertGreaterThan(plain.flash, 0.2, "the lighthouse flashes in the first second")
        XCTAssertLessThanOrEqual(gentle.glow, plain.glow * 0.55, "gentle visuals calm the glow")
        XCTAssertLessThanOrEqual(gentle.flash, plain.flash * 0.55, "and the lighthouse")
    }

    func testFirefliesOnTheHeadlandsOnHumidNights() throws {
        let humid = try renderBay(notes: [], at: 1, sky: Self.sky(hour: 22, weather: .humid))
        XCTAssertGreaterThan(humid.frame.sky.fireflies, 0.5, "a humid night")
        XCTAssertGreaterThan(humid.renderer.weather.fireflyCount, 0, "fireflies over the shore")
        let clear = try renderBay(notes: [], at: 1)
        XCTAssertEqual(clear.renderer.weather.fireflyCount, 0, "none on a clear night")
    }

    func testBayFramesAnyAspect() throws {
        for (w, h) in [(864, 360), (360, 360)] {
            let shot = try renderBay(notes: [21, 60, 64, 67, 108], at: 1.5, width: w, height: h)
            let r = shot.renderer
            XCTAssertEqual(r.keyRects.count, 88)
            for k in r.keyRects {
                XCTAssertGreaterThanOrEqual(k.x, -1); XCTAssertLessThanOrEqual(k.z, 1)
                XCTAssertGreaterThanOrEqual(k.y, -1); XCTAssertLessThanOrEqual(k.w, 1)
            }
            let keyTop = r.keyRects.map(\.w).max() ?? -1
            XCTAssertTrue(r.waterlineY > keyTop && r.waterlineY < r.horizonY && r.horizonY < 1, "\(w)×\(h): sand, water, sky in order")
            for (name, p) in [("lantern", r.lanternScreen), ("lighthouse", r.lighthouseScreen)] {
                XCTAssertTrue(abs(p.x) < 0.95 && p.y > r.waterlineY && p.y < 0.95, "\(w)×\(h): the \(name) at \(p)")
            }
            XCTAssertEqual(r.patchCount, 5)
            for patch in shot.frame.patches {
                let box = try XCTUnwrap(r.screenBox(of: patch))
                XCTAssertTrue(abs(box.centre.x) + box.half.x < 1, "\(w)×\(h): note \(patch.note)'s glow is in view")
            }
            XCTAssertGreaterThan(PreviewRenderer.stats(shot.image).variance, 0.0008, "\(w)×\(h)")
        }
    }

    func testBayBurstStaysInBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(BioluminescentBayRenderer(device: device))
        let d = SceneDirector(themeID: BioluminescentBayModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        d.sky.reset(settings: Self.sky(hour: 22))
        for q in [QualityLevel.lite, .high] {
            let start = Date()
            for i in 0..<60 {
                let t = Double(i) / 60
                d.handle((0..<34).map { k in .noteOn(note: UInt8(21 + (i * 34 + k) % 88), velocity: 0.8) }, at: t)
                let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: q) as? BayFrame)
                r.update(f, params: d.parameters, quality: q, gentle: false, dt: 1.0 / 60, size: CGSize(width: 640, height: 360))
                XCTAssertLessThanOrEqual(r.patchCount, BioluminescentBayRenderer.patchBudget(q))
                XCTAssertLessThanOrEqual(r.patchCount, GlowWake.cap)
                XCTAssertLessThanOrEqual(r.wakeCount, BioluminescentBayRenderer.wakeBudget(q))
                XCTAssertLessThanOrEqual(r.dartCount, BioluminescentBayRenderer.dartBudget(q))
                XCTAssertNotNil(preview.capture(r))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 4, "\(q)")
        }
        XCTAssertGreaterThan(r.patchCount, 0)
    }
}

extension WorldPreviewTests {
    func testWriteBayPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let night = ThemeState()   // the world's default: held at Deep night
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        let warp = ThemeState(values: ["visual": .choice("Galaxy Warp")])
        let sky = BioluminescentBayRendererTests.sky
        // At 17:00 on the frozen date the star clock puts Crux 12–17° up over the left headland and the Pointers over
        // the bay's mouth (the light is held at Deep night).
        let cases: [(String, SkySettings, ThemeState, QualityLevel, Double)] = [
            ("bay-night", sky(17, .clear, 0.1), night, .high, 5),
            ("bay-night-glow-t3", sky(17, .clear, 0.1), night, .high, 3),
            ("bay-humid-fireflies", sky(17, .humid, 0.1), night, .high, 5),
            ("bay-dawn", sky(7.1, .clear, 0.3), follow, .high, 5),
            ("bay-noon", sky(13, .clear, 0.5), follow, .high, 5),
            ("bay-rain", sky(17, .rain, 0.1), night, .high, 5),
            ("bay-smooth", sky(17, .clear, 0.1), night, .lite, 5),
            ("bay-warp-t7", sky(17, .clear, 0.1), warp, .high, 7),
        ]
        for (name, s, state, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: BioluminescentBayModel.id, at: [t], state: state, quality: q, sky: s,
                                                     mood: .secretGlow).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
    }
}
