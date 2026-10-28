import Foundation

public enum TimeMode: String, Codable, CaseIterable { case quick, realTime, frozen }
public enum WeatherKind: String, Codable, CaseIterable { case clear, lightCloud, overcast, mist, drizzle, rain, storm, snow }
public enum WeatherMode: String, Codable, CaseIterable { case pick, randomBeautiful }
public struct SkySettings: Codable, Equatable {
    public var timeMode: TimeMode = .quick
    public var dayMinutes: Double = 12
    public var frozenHour: Double = 21
    public var frozenPhase: Double = 0.5
    public var cityID: String?
    public var weatherMode: WeatherMode = .randomBeautiful
    public var weather: WeatherKind = .clear
    public init() {}
}
public struct AmbienceSettings: Codable, Equatable {
    public var enabled = true
    public var volume: Double = 0.25
    public var closeness: Double = 0.5
    public init() {}
}
public struct SkyState: Equatable {
    public var sun = SkyDirection(azimuth: 0, altitude: 0), moon = SkyDirection(azimuth: 0, altitude: 0)
    public var moonPhase = 0.0, moonLit = 0.0, siderealDegrees = 0.0, latitude = 0.0
    public var zenith = SIMD3<Float>(repeating: 0), horizon = SIMD3<Float>(repeating: 0)
    public var starVisibility: Float = 0
    public var weather = WeatherKind.clear, weatherBlend: Float = 0, nextWeather = WeatherKind.clear
    public var cloudCover: Float = 0, rain: Float = 0, snow: Float = 0, mist: Float = 0, wind: Float = 0, lightning: Float = 0
    public var hourOfDay = 0.0
    public var subsolar = GeoPoint(latitude: 0, longitude: 0)
}
public final class LivingSky {
    public var settings: SkySettings
    public let location = GeoPoint(latitude: 0, longitude: 0)
    public init(settings: SkySettings, seed: UInt64 = 1, homeZone: TimeZone = .current) { self.settings = settings }
    public func step(now: Date, dt: Double) -> SkyState { SkyState() }
}
