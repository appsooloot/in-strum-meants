import SwiftUI
import InStrumCore

/// The Sets at the top of ✦ Visuals: one tap brings a world, its visual, a built-in instrument and an ambience
/// together under one mood. A changed set shows "Modified" with Restore.
struct SetsGallery: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            ForEach(SetLibrary.all) { set in
                SetCard(set: set, active: model.activeSetID == set.id,
                        modified: model.activeSetID == set.id && model.isSetModified,
                        apply: { Task { await model.applySet(set.id) } },
                        restore: { Task { await model.restoreSet() } })
            }
        }
    }

    /// Each set's card colours (original, from its world and mood).
    static func tint(for id: String) -> [Color] {
        switch id {
        case SetLibrary.moonlitLake.id: return [Color(red: 0.05, green: 0.07, blue: 0.16), Color(red: 0.22, green: 0.27, blue: 0.40)]
        case SetLibrary.spaceshipLounge.id: return [Color(red: 0.09, green: 0.04, blue: 0.18), Color(red: 0.16, green: 0.30, blue: 0.55)]
        default: return [Color(white: 0.12), Color(white: 0.22)]
        }
    }
}

struct SetCard: View {
    let set: InStrumSet
    let active: Bool
    let modified: Bool
    let apply: () -> Void
    let restore: () -> Void

    private var credit: Credit? { CreditLibrary.credit(id: set.creditID) }

    var body: some View {
        Button(action: apply) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(set.name).font(.headline)
                    Spacer()
                    if modified {
                        Text("Modified").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.18)))
                        Button("Restore", action: restore).font(.caption).buttonStyle(.borderless)
                    } else if active {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white.opacity(0.85))
                    }
                }
                Text(set.moodName).font(.caption).foregroundStyle(.white.opacity(0.75))
                if let credit {
                    Text("Inspired by “\(credit.song)” · \(credit.artist)")
                        .font(.caption2).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: SetsGallery.tint(for: set.id), startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(active ? 0.55 : 0.12), lineWidth: active ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(set.name) set, \(set.moodName)\(modified ? ", modified" : "")")
    }
}
