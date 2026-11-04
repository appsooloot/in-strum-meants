import SwiftUI

/// Hold the moment (Small Wins spec §4): the hourglass in the main bar. Empty until holding lands.
struct HoldPad: View {
    @ObservedObject var model: AppModel

    var body: some View { EmptyView() }
}

/// The Play menu's hold item: Hold the Moment (⌘⇧H). Empty until holding lands.
struct HoldMenuItems: View {
    @ObservedObject var model: AppModel

    var body: some View { EmptyView() }
}
