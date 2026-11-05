import SwiftUI

/// Keep that (Small Wins spec §2): the bookmark in the main bar. Empty until keeping lands.
struct KeepButton: View {
    @ObservedObject var model: AppModel

    var body: some View { EmptyView() }
}

/// The Play menu's keep items: Keep That (⌘K) and Keep the Last 10 Minutes. Empty until keeping lands.
struct KeepMenuItems: View {
    @ObservedObject var model: AppModel

    var body: some View { EmptyView() }
}
