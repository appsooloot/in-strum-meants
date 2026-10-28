import SwiftUI

/// Card art (RED stub).
enum CardArt {
    case comeBackToEarth, innerbloom
    static func art(for creditID: String) -> CardArt? { nil }
    func draw(in ctx: GraphicsContext, size: CGSize, t: Double, pulse: Double) {}
}
