import Foundation

public struct City: Codable, Equatable, Identifiable {
    public let id: String
    public let name, country: String
    public let point: GeoPoint
    public let timeZoneID: String
}
public enum Cities {
    public static let all: [City] = []
    public static func city(id: String) -> City? { nil }
    public static func defaultCity(for: TimeZone) -> City? { nil }
}
