import SwiftUI

/// The toast over the canvas ("Kept · 4:12", "Nothing to keep yet", "You're awake."): a small capsule at the top that
/// fades in and clears itself after a moment (`AppModel.showToast`). It never takes a click.
struct ToastBanner: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var appearing: AnyTransition {
        reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .move(edge: .top))
    }

    var body: some View {
        ZStack {
            if let toast = model.toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.symbol)
                        .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.63))
                    Text(toast.text)
                        .lineLimit(1)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.12)) }
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
                .accessibilityElement(children: .combine)
                .id(toast.id)
                .transition(appearing)
            }
        }
        .padding(.top, 14)
        .animation(.easeInOut(duration: 0.25), value: model.toast)
        .allowsHitTesting(false)
    }
}
