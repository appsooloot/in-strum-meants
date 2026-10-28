import SwiftUI
import AppKit
import InStrumCore

/// The living "Inspired by" card: original art that breathes at the song's tempo, the song in the card's own
/// type, liner-note micro type (key · track · tempo) and a Listen link. Words and a link only — no artwork,
/// no logos, no lyrics.
struct InspiredByCard: View {
    let credit: Credit
    /// A fixed moment (previews); nil animates while the card is on screen.
    var fixedTime: Double?
    @State private var visible = false
    @State private var showLine = false

    private var art: CardArt? { CardArt.art(for: credit.id) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            canvas
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text("INSPIRED BY").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.white.opacity(0.7))
                Text(art?.titleCase == true ? credit.song.uppercased() : credit.song)
                    .font(art?.titleFont ?? .title2).tracking(art?.titleTracking ?? 0)
                    .foregroundStyle(.white)
                Text("\(credit.artist) · \(credit.album) · \(String(credit.year))")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                Text(credit.line)
                    .font(.system(size: 12).italic()).foregroundStyle(.white.opacity(0.85))
                    .opacity(showLine || fixedTime != nil ? 1 : 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            Text("\(credit.key) · TRACK \(credit.trackNumber) · \(Int(credit.tempoBPM.rounded())) BPM")
                .font(.system(size: 9, weight: .medium).monospacedDigit()).tracking(1.2)
                .foregroundStyle(.white.opacity(0.6))
                .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            Button { Self.listen(to: credit) } label: {
                Label("Listen", systemImage: "play.circle.fill").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("Find “\(credit.song)” on Spotify")
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .aspectRatio(5.0 / 3.0, contentMode: .fit)
        .onHover { inside in withAnimation(.easeInOut(duration: 1.2)) { showLine = inside } }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Inspired by \(credit.song) by \(credit.artist), \(credit.album), \(String(credit.year)). \(credit.line)")
    }

    @ViewBuilder
    private var canvas: some View {
        if let t = fixedTime {
            Canvas { ctx, size in art?.draw(in: ctx, size: size, t: t, pulse: credit.pulsePeriod) }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !visible)) { tl in
                Canvas { ctx, size in
                    art?.draw(in: ctx, size: size, t: tl.date.timeIntervalSinceReferenceDate, pulse: credit.pulsePeriod)
                }
            }
        }
    }

    /// Opens the Spotify app's search, or the web search when the app isn't installed.
    static func listen(to credit: Credit) {
        let app = ListenLink.spotifyApp(for: credit)
        if NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
        } else {
            NSWorkspace.shared.open(ListenLink.spotifyWeb(for: credit))
        }
    }
}
