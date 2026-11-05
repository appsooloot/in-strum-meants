import SwiftUI

/// The sleep timer (Small Wins spec §3): the moon in the main bar, with the time left beside it. Empty until the
/// timer lands.
struct SleepMenu: View {
    @ObservedObject var model: AppModel

    var body: some View { EmptyView() }
}
