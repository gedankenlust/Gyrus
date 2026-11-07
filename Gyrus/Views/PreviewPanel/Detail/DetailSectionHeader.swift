import SwiftUI

/// The one heading style for sections inside the bookmark detail (Overview
/// details, similar bookmarks). Sharing it keeps sections visually equal and
/// gives VoiceOver users a heading to jump to.
struct DetailSectionHeader: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
