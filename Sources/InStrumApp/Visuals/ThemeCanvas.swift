import MetalKit
import QuartzCore
import InStrumCore
import InStrumAudio

/// Runs the active theme every frame: events → director → theme renderer → finishing → screen.
final class ThemeCanvas: NSObject, MTKViewDelegate {
    private let model: AppModel
    private let queue: MTLCommandQueue
    private let device: MTLDevice
    private let director: SceneDirector
    private var stack: RenderStack?
    private var butterfly: ButterflyRenderer?
    private var steinway: SteinwayRenderer?
    private var moonlitLake: MoonlitLakeRenderer?
    private var lounge: SpaceshipLoungeRenderer?
    private var beach: GoldenHourBeachRenderer?
    private var road: CoastRoadRenderer?
    private var cabin: SnowboundCabinRenderer?
    private var bedroom: BedroomDawnRenderer?
    private var fjord: AuroraFjordRenderer?
    private var bay: BioluminescentBayRenderer?
    private var teaHouse: TeaHouseSnowRenderer?
    private var zenGarden: ZenRockGardenRenderer?
    private var autoQuality: AutoQuality
    private var lastTime: CFTimeInterval = 0
    private var seenVersion = -1
    private var level: QualityLevel = .lite

    @MainActor
    init?(view: MTKView, model: AppModel) {
        guard let device = view.device, let queue = device.makeCommandQueue(),
              let stack = RenderStack(device: device, pixelFormat: view.colorPixelFormat) else { return nil }
        self.model = model
        self.device = device
        self.queue = queue
        self.stack = stack
        self.director = SceneDirector(themeID: model.themeID, state: model.themeState(for: model.themeID),
                                      reaction: model.reaction)
        self.autoQuality = AutoQuality(setting: model.quality)
        super.init()
        director.sky.reset(settings: model.skySettings)   // launch with the chosen weather, not a blend into it
    }

    /// What the ambience should play for a frame: a world's own soundscape, silence for the other themes.
    static func ambience(for frame: Any) -> AmbienceScene { (frame as? AmbienceProviding)?.ambience ?? .silent }

    /// The same with the key the player is in (spec §7.1), for the in-key sources. Every theme carries it, so a bell
    /// heard after a switch to a world already sits in your key.
    static func ambience(for frame: Any, key: AmbienceKey?) -> AmbienceScene {
        var scene = ambience(for: frame)
        scene.key = key
        return scene
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { stack?.resize(width: Int(size.width), height: Int(size.height)) }
    }

    func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame(view) }
    }

    @MainActor
    private func syncSettings() {
        guard model.visualsVersion != seenVersion else { return }
        seenVersion = model.visualsVersion
        if model.themeID != director.themeID {
            director.switchTheme(to: model.themeID, state: model.themeState(for: model.themeID))
        } else {
            director.parameters = ThemeRegistry.parameterSet(for: director.themeID, state: model.themeState(for: director.themeID))
        }
        autoQuality.setting = model.quality
        director.reaction = model.reaction
        director.sky.settings = model.skySettings
        director.mood = model.mood
    }

    @MainActor
    private func drawFrame(_ view: MTKView) {
        syncSettings()
        guard let stack else { return }
        let now = CACurrentMediaTime()
        let frameTime = lastTime == 0 ? 0 : max(0, now - lastTime)
        let dt = min(0.1, frameTime)
        lastTime = now
        level = autoQuality.record(frameTime: frameTime)
        let backing = view.window?.backingScaleFactor ?? 2
        let px = RenderScale.pixels(points: (Double(view.bounds.width), Double(view.bounds.height)),
                                    backingScale: Double(backing), quality: level)
        let wanted = CGSize(width: px.width, height: px.height)
        if view.drawableSize != wanted { view.drawableSize = wanted }
        let size = view.drawableSize
        stack.resize(width: Int(size.width), height: Int(size.height))
        director.handle(model.drainEvents(), at: now)
        let sound = model.soundReading
        let hub = director.hub
        hub.set(.attack, sound.attack, at: now)
        hub.set(.brightness, sound.brightness, at: now)
        hub.set(.ring, sound.ring, at: now)
        hub.set(.texture, sound.texture, at: now)
        hub.set(.loudness, sound.loudness, at: now)
        hub.set(.width, sound.width, at: now)
        for (address, value) in model.drainDialChanges() { hub.set(.dial(address), value, at: now) }
        let frame = director.step(dt: dt, t: now, quality: level)
        model.updateAmbience(Self.ambience(for: frame, key: director.key), at: now)

        let renderer: ThemeRenderer?
        if let g = frame as? GardenFrame {
            if butterfly == nil { butterfly = ButterflyRenderer(device: device) }
            butterfly?.update(g, params: director.parameters, quality: level, gentle: model.gentleVisuals, dt: dt, size: size)
            renderer = butterfly
        } else if let s = frame as? SteinwayFrame {
            if steinway == nil { steinway = SteinwayRenderer(device: device) }
            steinway?.update(s, quality: level, gentle: model.gentleVisuals, dt: dt)
            renderer = steinway
        } else if let l = frame as? LakeFrame {
            if moonlitLake == nil { moonlitLake = MoonlitLakeRenderer(device: device) }
            moonlitLake?.update(l, params: director.parameters, quality: level, gentle: model.gentleVisuals, dt: dt, size: size)
            renderer = moonlitLake
        } else if let l = frame as? LoungeFrame {
            if lounge == nil { lounge = SpaceshipLoungeRenderer(device: device) }
            lounge?.update(l, params: director.parameters, quality: level, gentle: model.gentleVisuals, dt: dt, size: size)
            renderer = lounge
        } else if let b = frame as? BeachFrame {
            if beach == nil { beach = GoldenHourBeachRenderer(device: device) }
            beach?.update(b, params: director.parameters, quality: level, gentle: model.gentleVisuals, dt: dt, size: size)
            renderer = beach
        } else if let r = frame as? RoadFrame {
            if road == nil { road = CoastRoadRenderer(device: device) }
            road?.update(r, params: director.parameters, quality: level, gentle: model.gentleVisuals, dt: dt, size: size)
            renderer = road
        } else if let c = frame as? CabinFrame {
            if cabin == nil { cabin = SnowboundCabinRenderer(device: device) }
            cabin?.update(c, params: director.parameters, quality: level, gentle: model.gentleVisuals, dt: dt, size: size)
            renderer = cabin
        } else if let b = frame as? BedroomFrame {
            if bedroom == nil { bedroom = BedroomDawnRenderer(device: device) }
            bedroom?.update(b, params: director.parameters, quality: level, gentle: model.gentleVisuals, dt: dt, size: size)
            renderer = bedroom
        } else if let f = frame as? FjordFrame {
            if fjord == nil { fjord = AuroraFjordRenderer(device: device) }
            fjord?.update(f, params: director.parameters, quality: level, gentle: model.gentleVisuals, dt: dt, size: size)
            renderer = fjord
        } else if let y = frame as? BayFrame {
            if bay == nil { bay = BioluminescentBayRenderer(device: device) }
            bay?.update(y, params: director.parameters, quality: level, gentle: model.gentleVisuals, dt: dt, size: size)
            renderer = bay
        } else if let h = frame as? TeaHouseFrame {
            if teaHouse == nil { teaHouse = TeaHouseSnowRenderer(device: device) }
            teaHouse?.update(h, params: director.parameters, quality: level, gentle: model.gentleVisuals, dt: dt, size: size)
            renderer = teaHouse
        } else if let z = frame as? ZenGardenFrame {
            if zenGarden == nil { zenGarden = ZenRockGardenRenderer(device: device) }
            zenGarden?.update(z, params: director.parameters, quality: level, gentle: model.gentleVisuals, dt: dt, size: size)
            renderer = zenGarden
        } else {
            renderer = nil
        }
        guard let renderer, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        renderer.render(stack: stack, commandBuffer: cb)
        stack.post(into: pass, commandBuffer: cb, settings: renderer.post)
        cb.present(drawable)
        cb.commit()
    }
}
