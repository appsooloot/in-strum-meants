import Foundation

public struct GeoPoint: Codable, Equatable { public var latitude, longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude } }
public struct SkyDirection: Equatable { public var azimuth, altitude: Double }
public enum MoonPhaseEvent { case new, firstQuarter, full, lastQuarter }
public enum Solar {
    public static func direction(at: Date, from: GeoPoint) -> SkyDirection { SkyDirection(azimuth: 0, altitude: 0) }
    public static func sunrise(on day: Date, at: GeoPoint, timeZone: TimeZone) -> Date? { nil }
    public static func sunset(on day: Date, at: GeoPoint, timeZone: TimeZone) -> Date? { nil }
    public static func subsolarPoint(at: Date) -> GeoPoint { GeoPoint(latitude: 0, longitude: 0) }
}
public enum Lunar {
    struct Equatorial { var rightAscension, declination, distanceKm: Double }
    static func equatorial(at: Date) -> Equatorial { Equatorial(rightAscension: 0, declination: 0, distanceKm: 0) }
    public static func direction(at: Date, from: GeoPoint) -> SkyDirection { SkyDirection(azimuth: 0, altitude: 0) }
    public static func phaseAngle(at: Date) -> Double { 0 }
    public static func illuminatedFraction(at: Date) -> Double { 0.5 }
    public static func next(_ phase: MoonPhaseEvent, after: Date) -> Date { after }
    public static func moonrise(on day: Date, at: GeoPoint, timeZone: TimeZone) -> Date? { nil }
    public static func moonset(on day: Date, at: GeoPoint, timeZone: TimeZone) -> Date? { nil }
}
public enum Sidereal { public static func localSiderealDegrees(at: Date, longitude: Double) -> Double { 0 } }
